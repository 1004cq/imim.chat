#!/bin/bash
set -euo pipefail
sticker_script_dir="$(cd "$(dirname "$0")" && pwd)"
sticker_source="$sticker_script_dir/../App/StickerMedia.swift"
sticker_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/imim-sticker-regression.XXXXXX")"
# Synthetic test data only. No owner's conversations, files, cache or account.
node - "$sticker_test_dir" <<'JS'
const fs = require('node:fs'), zlib = require('node:zlib');
const dir = process.argv[2];
const json = Buffer.from(JSON.stringify({v:'5.7.4',fr:60,ip:0,op:180,w:512,h:512,layers:[],assets:[]}));
fs.writeFileSync(dir + '/fixture.json', json);
fs.writeFileSync(dir + '/fixture.tgs', zlib.gzipSync(json));
fs.writeFileSync(dir + '/oversized.tgs', zlib.gzipSync(Buffer.alloc(4_194_305, 120)));
JS
node - "$sticker_source" "$sticker_script_dir/StickerPlaybackRegression.swift" <<'JS' |
const fs = require('node:fs');
const text = fs.readFileSync(process.argv[2], 'utf8');
const policy = text.split('// MARK: Sticker playback policy')[1].split('// MARK: UI-owned playback leases')[0];
const links = text.split('enum StickerPackLink {')[1].split('struct StickerInstallResponse')[0];
process.stdout.write('import Foundation\nimport CoreGraphics\nimport zlib\n// MARK: Sticker playback policy' + policy + '\nenum StickerPackLink {' + links + '\n' + fs.readFileSync(process.argv[3], 'utf8'));
JS
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc \
    -O -swift-version 6 -strict-concurrency=complete -parse-as-library - \
    -o "$sticker_test_dir/StickerPlaybackRegression"
"$sticker_test_dir/StickerPlaybackRegression" "$sticker_test_dir"
printf 'Regression artifacts retained: %s\n' "$sticker_test_dir"
