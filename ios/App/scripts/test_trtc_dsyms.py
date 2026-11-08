#!/usr/bin/env python3
"""Exercise archive symbol safety using genuine compiler-generated Mach-O fixtures."""
import argparse
import importlib.util
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('trtc_symbols', Path(__file__).with_name('trtc-dsyms.py'))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class SymbolSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix='imim-dsym-fixtures-')
        cls.base = Path(cls.fixtures.name)
        cls.arch = platform.machine()
        for label, value in [('matching', 1), ('different', 2)]:
            folder = cls.base / label
            folder.mkdir()
            code = folder / 'sample.c'
            code.write_text('int main(void) { return %d; }\n' % value)
            obj = folder / 'sample.o'
            subprocess.run(['xcrun', 'clang', '-g', '-O0', '-c', str(code), '-o', str(obj)], check=True)
            subprocess.run(['xcrun', 'clang', str(obj), '-o', str(folder / 'Fixture')], check=True)
            subprocess.run(['xcrun', 'dsymutil', str(folder / 'Fixture'), '-o', str(folder / 'Fixture.framework.dSYM')], check=True)
            debug = subprocess.check_output(['xcrun', 'dwarfdump', '--debug-info', str(folder / 'Fixture.framework.dSYM')], text=True)
            assert 'DW_TAG_compile_unit' in debug, 'Fixture must contain real DWARF debug information'

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='imim-dsym-test-')
        self.root = Path(self.work.name)
        self.frameworks = self.root / 'frameworks'
        binary_dir = self.frameworks / 'Fixture.framework'
        binary_dir.mkdir(parents=True)
        shutil.copy2(self.base / 'matching/Fixture', binary_dir / 'Fixture')
        self.symbols = self.root / 'symbols'
        self.symbols.mkdir()
        shutil.copytree(self.base / 'matching/Fixture.framework.dSYM', self.symbols / 'Fixture.framework.dSYM')
        self.destination = self.root / 'archive-symbols'

    def tearDown(self):
        self.work.cleanup()

    def args(self, **changes):
        values = dict(framework_root=self.frameworks, symbols_root=self.symbols,
                      destination=self.destination, framework=['Fixture'], arch=[self.arch], dry_run=False)
        values.update(changes)
        return argparse.Namespace(**values)

    def test_real_matching_symbols_are_copied_and_idempotent(self):
        helper.copy_symbols(self.args())
        target = self.destination / 'Fixture.framework.dSYM/Contents/Resources/DWARF/Fixture'
        expected = helper.uuids(self.frameworks / 'Fixture.framework/Fixture')
        self.assertEqual(helper.uuids(target), expected)
        checksum = helper.digest(target)
        helper.copy_symbols(self.args())
        self.assertEqual(helper.digest(target), checksum)

    def test_dry_run_writes_nothing(self):
        helper.copy_symbols(self.args(dry_run=True))
        self.assertFalse(self.destination.exists())

    def test_wrong_vendor_uuid_cannot_enter_archive(self):
        bad = self.root / 'wrong-symbols'
        shutil.copytree(self.base / 'different/Fixture.framework.dSYM', bad / 'Fixture.framework.dSYM')
        with self.assertRaisesRegex(RuntimeError, 'Missing UUID-matched'):
            helper.copy_symbols(self.args(symbols_root=bad))
        self.assertFalse(self.destination.exists())

    def test_existing_different_symbols_are_preserved(self):
        target = self.destination / 'Fixture.framework.dSYM'
        shutil.copytree(self.base / 'different/Fixture.framework.dSYM', target)
        before = helper.digest(helper.dwarf(target, 'Fixture'))
        with self.assertRaisesRegex(RuntimeError, 'preserving them'):
            helper.copy_symbols(self.args())
        self.assertEqual(helper.digest(helper.dwarf(target, 'Fixture')), before)

    def test_missing_architecture_blocks_all_writes(self):
        with self.assertRaisesRegex(RuntimeError, 'lacks a requested architecture'):
            helper.copy_symbols(self.args(arch=['not-a-real-architecture']))
        self.assertFalse(self.destination.exists())

    def test_later_missing_framework_does_not_partially_copy(self):
        with self.assertRaises((OSError, RuntimeError)):
            helper.copy_symbols(self.args(framework=['Fixture', 'Missing']))
        self.assertFalse(self.destination.exists())

    def test_wrong_sdk_download_checksum_is_rejected(self):
        archive = self.root / 'bad.zip'
        archive.write_bytes(b'wrong vendor download')
        cache = self.root / 'cache'
        with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
            helper.prepare(argparse.Namespace(version=helper.SDK_VERSION, sdk_zip=archive, cache_root=cache))
        self.assertFalse((cache / helper.SDK_VERSION).exists())


if __name__ == '__main__':
    unittest.main()
