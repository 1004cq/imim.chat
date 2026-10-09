#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-chat-image-decode.XXXXXX)
node - <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync('App/ChatDetailView.swift', 'utf8');
const view = source.slice(source.indexOf('private struct AuthenticatedRemoteImage'), source.indexOf('// MARK: - Chat image decoder'));
assert.ok(view.includes('.task(id: decodeRequest)'));
assert.ok(view.includes('.onDisappear { image = nil }'));
assert.ok(view.includes('try Task.checkCancellation()\n            image = UIImage(cgImage:'));
assert.ok(view.includes('guard !Task.isCancelled, !(error is CancellationError)'));
assert.ok(view.includes('input.url.path.hasPrefix("/api/")'));
assert.ok(!view.includes('Data(contentsOf:') && !view.includes('UIImage(data:'));
assert.ok(source.includes('.frame(width: 190, height: 140)'));
console.log('PASS: actual image View task identity, cancellation-before-publish, release, auth and fixed layout source guards (not a SwiftUI runtime test)');
JS
{
    printf 'import Foundation\nimport CoreGraphics\nimport ImageIO\n'
    sed -n '/^\/\/ MARK: - Chat image decoder/,/^\/\/ MARK: - End chat image decoder/p' App/ChatDetailView.swift
    cat scripts/ChatImageDecodeRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
    -O -swift-version 6 -strict-concurrency=complete -D CHAT_IMAGE_DECODER_TESTS -parse-as-library - \
    -o "$test_dir/ChatImageDecodeRegression"
"$test_dir/ChatImageDecodeRegression"
