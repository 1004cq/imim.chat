#!/usr/bin/env python3
"""Prepare genuine vendor dSYMs and copy only UUID-matched symbols to archives."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

SDK_VERSION = '13.5.21355'
SDK_URL = 'https://liteav.sdk.qcloud.com/download/releases/13.5/TXLiteAVSDK_TRTC_iOS_13.5.21355_SDK_en.zip'
SDK_SHA256 = '86b52f8d8dae588faf54b09d68cf63c2d707c15cfd80282f53103eb80900561a'
FRAMEWORKS = ['TXLiteAVSDK_TRTC', 'TXFFmpeg', 'TXSoundTouch']


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    result = {arch: uuid.upper() for uuid, arch in re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', output)}
    if not result:
        raise RuntimeError('No Mach-O UUIDs: ' + str(path))
    return result


def dwarf(bundle, name):
    return bundle / 'Contents/Resources/DWARF' / name


def verify_cache(cache):
    manifest = json.loads((cache / 'manifest.json').read_text())
    if manifest['sdkVersion'] != SDK_VERSION or manifest['sdkZipSHA256'] != SDK_SHA256:
        raise RuntimeError('Symbol cache provenance does not match the pinned SDK')
    for item in manifest['symbols']:
        f = dwarf(cache / (item['framework'] + '.framework.dSYM'), item['framework'])
        if digest(f) != item['sha256'] or uuids(f) != item['uuids']:
            raise RuntimeError('Corrupt or mismatched cached symbols: ' + item['framework'])
    if {i['framework'] for i in manifest['symbols']} != set(FRAMEWORKS):
        raise RuntimeError('Incomplete symbol cache')
    return manifest


def prepare(args):
    if args.version != SDK_VERSION:
        raise RuntimeError('No pinned symbol source for SDK ' + args.version)
    cache = args.cache_root / args.version
    if cache.exists():
        verify_cache(cache)
        print('Verified existing vendor symbol cache: ' + str(cache))
        return
    args.cache_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.trtc-prepare-', dir=args.cache_root) as work:
        work = Path(work)
        sdk_zip = args.sdk_zip or work / 'sdk.zip'
        if not args.sdk_zip:
            with urllib.request.urlopen(SDK_URL, timeout=60) as response, sdk_zip.open('wb') as out:
                total = 0
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > 128 * 1024 * 1024:
                        raise RuntimeError('SDK archive exceeds the download bound')
                    out.write(chunk)
        if digest(sdk_zip) != SDK_SHA256:
            raise RuntimeError('Official SDK ZIP checksum mismatch; no symbols installed')
        staged = work / 'symbols'
        staged.mkdir()
        entries = []
        with zipfile.ZipFile(sdk_zip) as archive:
            for name in FRAMEWORKS:
                prefix = 'TXLiteAVSDK_TRTC/dSYMs/' + name + '_arm64.dSYM/'
                target = staged / (name + '.framework.dSYM')
                expanded = 0
                for info in archive.infolist():
                    if not info.filename.startswith(prefix) or info.is_dir():
                        continue
                    relative = PurePosixPath(info.filename[len(prefix):])
                    if relative.is_absolute() or '..' in relative.parts or (info.external_attr >> 16) & 0o170000 == 0o120000:
                        raise RuntimeError('Unsafe path in SDK archive')
                    expanded += info.file_size
                    if expanded > 128 * 1024 * 1024:
                        raise RuntimeError('Symbols exceed the extraction bound')
                    f = target / str(relative)
                    f.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(info) as source, f.open('wb') as out:
                        shutil.copyfileobj(source, out)
                f = dwarf(target, name)
                symbols = uuids(f)
                subprocess.run(['xcrun', 'dwarfdump', '--verify', str(f)], check=True, stdout=subprocess.DEVNULL)
                entries.append({'framework': name, 'uuids': symbols, 'sha256': digest(f)})
        (staged / 'manifest.json').write_text(json.dumps({'sdkVersion': SDK_VERSION, 'sourceURL': SDK_URL,
            'sdkZipSHA256': SDK_SHA256, 'symbols': entries}, indent=2) + '\n')
        verify_cache(staged)
        # A pre-existing cache is never overwritten or removed.
        if cache.exists():
            verify_cache(cache)
        else:
            os.rename(staged, cache)
        print('Prepared genuine vendor symbols: ' + str(cache))


def framework_binary(root, name, architectures):
    direct = root / (name + '.framework') / name
    if direct.is_file():
        return direct
    xc = root / (name + '.xcframework')
    info = plistlib.loads((xc / 'Info.plist').read_bytes())
    for library in info['AvailableLibraries']:
        if library.get('SupportedPlatform') == 'ios' and not library.get('SupportedPlatformVariant'):
            if set(architectures).issubset(library['SupportedArchitectures']):
                return xc / library['LibraryIdentifier'] / library['LibraryPath'] / name
    raise RuntimeError('No device framework slice for ' + name)


def copy_symbols(args):
    if not args.arch:
        raise RuntimeError('Explicit archive architectures are required')
    if (args.symbols_root / 'manifest.json').is_file():
        verify_cache(args.symbols_root)
    # Validate every framework before writing any archive output.
    plan = []
    for name in args.framework:
        binary = framework_binary(args.framework_root, name, args.arch)
        expected = uuids(binary)
        required = {arch: expected[arch] for arch in args.arch if arch in expected}
        if set(required) != set(args.arch):
            raise RuntimeError('Framework lacks a requested architecture: ' + name)
        matches = []
        for candidate in args.symbols_root.rglob('*.dSYM'):
            f = dwarf(candidate, name)
            if f.is_file() and all(uuids(f).get(a) == u for a, u in required.items()):
                matches.append(candidate)
        if not matches:
            raise RuntimeError('Missing UUID-matched vendor dSYM for ' + name + ': ' + json.dumps(required))
        source = matches[0]
        if any(digest(dwarf(other, name)) != digest(dwarf(source, name)) for other in matches[1:]):
            raise RuntimeError('Ambiguous symbol contents with matching UUIDs: ' + name)
        target = args.destination / (name + '.framework.dSYM')
        if target.exists() and (not dwarf(target, name).is_file() or digest(dwarf(target, name)) != digest(dwarf(source, name))):
            raise RuntimeError('Existing archive symbols differ; preserving them: ' + str(target))
        plan.append((name, source, target, required))
    if not args.dry_run:
        args.destination.mkdir(parents=True, exist_ok=True)
        for name, source, target, required in plan:
            if not target.exists():
                with tempfile.TemporaryDirectory(prefix='.trtc-copy-', dir=args.destination) as work:
                    staged = Path(work) / target.name
                    shutil.copytree(source, staged)
                    if digest(dwarf(staged, name)) != digest(dwarf(source, name)):
                        raise RuntimeError('Symbol copy integrity check failed: ' + name)
                    os.rename(staged, target)
            if not all(uuids(dwarf(target, name)).get(a) == u for a, u in required.items()):
                raise RuntimeError('Copied UUID verification failed: ' + name)
    for name, _, target, required in plan:
        print(('Validated ' if args.dry_run else 'Archived ') + name + ': ' + json.dumps(required))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare')
    prep.add_argument('--version', required=True)
    prep.add_argument('--sdk-zip', type=Path)
    prep.add_argument('--cache-root', type=Path, default=Path.home() / 'Library/Caches/imim/TRTCSymbols')
    cp = commands.add_parser('copy')
    cp.add_argument('--framework-root', type=Path, required=True)
    cp.add_argument('--symbols-root', type=Path, required=True)
    cp.add_argument('--destination', type=Path, required=True)
    cp.add_argument('--framework', action='append', required=True)
    cp.add_argument('--arch', action='append', required=True)
    cp.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    try:
        prepare(args) if args.command == 'prepare' else copy_symbols(args)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print('error: TRTC symbols: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
