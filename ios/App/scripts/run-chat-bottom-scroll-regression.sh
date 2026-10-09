#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-chat-bottom-scroll.XXXXXX)
node - <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const view = fs.readFileSync('App/ChatDetailView.swift', 'utf8');
assert.ok(view.includes('@State private var bottomScrollPolicy = ChatBottomScrollPolicy()'));
assert.ok(view.includes('.modifier(ChatUserScrollTracking'));
assert.ok(view.includes('phase == .tracking || phase == .interacting || phase == .decelerating'));
assert.ok(view.includes('@GestureState private var isDragging = false'));
assert.ok(view.includes('@Environment(\\.accessibilityReduceMotion)'));
assert.ok(view.includes('.onDisappear {\n            bottomScrollPolicy.cancel()'));
assert.ok(view.includes('if isScrolling { bottomScrollPolicy.cancel() }'));
assert.ok(view.includes('id: \\.element.messageId'));
assert.ok(view.includes('.id(message.messageId)'));
assert.ok(view.includes('VStack(spacing: 2)'));
assert.ok(view.includes('viewModel.sortedMessages(for: chat)'));
const scheduler = view.slice(view.indexOf('    private func scheduleScrollToBottom('), view.indexOf('    private func startCall('));
assert.ok(scheduler.indexOf('bottomScrollPolicy.request(') < scheduler.indexOf('DispatchQueue.main.async'));
assert.ok(scheduler.indexOf('bottomScrollPolicy.consume(') > scheduler.indexOf('DispatchQueue.main.async'));
assert.ok(scheduler.includes('isUserScrolling: isUserScrollingMessages, reduceMotion: reduceMotion'));
console.log('PASS: actual view admission/delivery/cancellation, native phase/fallback, Reduce Motion, IDs/layout integration guards');
JS
# Compile the actual value-only production policy, not a model of the policy.
# No App preferences, messages, SwiftData, API or network are read by this test.
{
    sed -n '/^\/\/ MARK: - Bottom scroll policy/,/^\/\/ MARK: - End bottom scroll policy/p' App/ChatDetailView.swift
    cat scripts/ChatBottomScrollRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
    -O -swift-version 6 -strict-concurrency=complete -parse-as-library - \
    -o "$test_dir/ChatBottomScrollRegression"
"$test_dir/ChatBottomScrollRegression"
