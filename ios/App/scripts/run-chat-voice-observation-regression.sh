#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-chat-voice-observation.XXXXXX)
node - <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const chat = fs.readFileSync('App/ChatDetailView.swift', 'utf8');
const voice = fs.readFileSync('App/VoiceMessageViews.swift', 'utf8');
const actual = fs.readFileSync('App/VoiceRecorderManager.swift', 'utf8');
const fixture = fs.readFileSync('scripts/ChatVoiceObservationRegression.swift', 'utf8');
const fields = s => s.split('\n').filter(s => s.trim().startsWith('@Published var')).map(s => s.trim());
assert.deepEqual(fields(fixture), fields(actual));
assert.ok(chat.includes('@StateObject private var voiceState = ChatVoiceRecordingState()'));
assert.ok(!chat.includes('@ObservedObject var voiceRecorder') && !chat.includes('@StateObject private var voiceRecorder'));
assert.ok(chat.includes('ChatVoicePlaybackBubble('));
assert.ok(chat.includes('ChatVoiceRecordingOverlay(recorder: voiceRecorder)'));
assert.ok(!chat.includes('duration: voiceRecorder.recordingDuration') && !chat.includes('waveform: voiceRecorder.liveWaveform'));
assert.ok(voice.includes('@ObservedObject var recorder: VoiceRecorderManager'));
assert.ok(voice.includes('VoiceRecordingOverlay(duration: recorder.recordingDuration,'));
assert.ok(voice.includes('@StateObject private var playback: ChatVoicePlaybackState'));
assert.ok(voice.includes('paused: !isAnimating || reduceMotion'));
assert.ok(!voice.includes('repeatForever') && !voice.includes('@State private var phase'));
assert.ok(chat.includes('voiceRecorder.togglePlayback(messageId: message.messageId, urlString: url.absoluteString)'));
console.log('PASS: actual chat/child observation boundaries, playback action and fixture publisher declaration guards');
JS
{
    printf 'import Foundation\nimport Combine\n'
    sed -n '/^\/\/ MARK: - Chat voice observation/,/^\/\/ MARK: - End chat voice observation/p' App/VoiceMessageViews.swift
    cat scripts/ChatVoiceObservationRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
    -O -swift-version 6 -strict-concurrency=complete -parse-as-library - \
    -o "$test_dir/ChatVoiceObservationRegression"
"$test_dir/ChatVoiceObservationRegression"
