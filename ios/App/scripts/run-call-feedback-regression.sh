#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-call-feedback.XXXXXX)
sdk=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)
flags=(-O -target arm64-apple-ios17.6-macabi -sdk "$sdk"
       -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include" -parse-as-library)
for variant in controller signaling; do
    extra=()
    if [[ $variant == controller ]]; then extra=(-swift-version 6 -strict-concurrency=complete -D CONTROLLER_ONLY); else extra=(-swift-version 5); fi
    {
        printf 'import Foundation\nimport Combine\nimport UIKit\nimport AVFoundation\nimport AudioToolbox\nimport CallKit\n'
        sed -n '/^\/\/ MARK: - Call waiting feedback/,/^\/\/ MARK: - End call waiting feedback/p' App/CallManager.swift
        if [[ $variant == signaling ]]; then cat App/VideoCallViewModel.swift; fi
        cat scripts/CallFeedbackRegression.swift
    } | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "${flags[@]}" "${extra[@]}" \
        - -o "$test_dir/$variant"
    "$test_dir/$variant"
done
node - <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict');
const call = fs.readFileSync('App/CallManager.swift', 'utf8');
for (const signature of ['func accept(uuid:', 'func end(uuid:', 'func providerDidReset', 'perform action: CXAnswerCallAction', 'perform action: CXEndCallAction']) {
  const start = call.indexOf(signature);
  assert.ok(start >= 0 && call.slice(start, start + 420).includes('waitingFeedback.stop'), signature);
}
const feedback = call.slice(call.indexOf('// MARK: - Call waiting feedback'));
assert.ok(!feedback.includes('.setActive(') && !feedback.includes('.setCategory('));
assert.ok(call.includes('waitingFeedback.stop(id: descriptor.uuid.uuidString)'));
console.log('PASS: CallKit answer/end/reset/report-error cleanup and no AudioSession takeover source guards (not device/CallKit runtime proof)');
JS
printf 'Call feedback harness artifacts: %s\n' "$test_dir"
