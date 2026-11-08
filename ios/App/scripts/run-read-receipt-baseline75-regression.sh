#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-read-receipt.XXXXXX)
node - <<'JS'
const fs = require('node:fs'), assert = require('node:assert/strict');
const view = fs.readFileSync('App/ChatDetailView.swift','utf8');
const model = fs.readFileSync('App/ChatDetailViewModel.swift','utf8');
const socket = fs.readFileSync('App/SocketManager.swift','utf8');
const receipt = socket.slice(socket.indexOf('case "read_receipt":'),socket.indexOf('case "recall_notify":'));
assert.ok(receipt.includes('MessageReadReceipt.decode(payload, from: envelope.from)'));
assert.ok(receipt.includes('self.connectAttempt == attempt'));
assert.ok(receipt.includes('AuthTokenStore.shared.token == token'));
assert.ok(receipt.includes('applyReadReceipt(receipt, owner: owner)'));
assert.ok(model.includes('ConversationPreferences.readReceiptsEnabled(for: chat.chatId)'));
assert.ok(!model.includes('scheduleDeliveryUpdates'), 'No timer may manufacture read status');
assert.equal((model.match(/MessageDeliveryState.merging\(/g)||[]).length,3);
// Build75 release excludes the unpublished sticker ACK coalescing path.
const gate = view.slice(view.indexOf('private func markVisibleMessagesAsRead()'),view.indexOf('private func unlockConversation()'));
assert.ok(gate.includes('scenePhase == .active, !isConversationLocked'));
assert.ok(gate.includes('activeConversationId == chat.chatId'));
const indicator = view.slice(view.indexOf('private var deliveryStatusView:'),view.indexOf('private struct HeaderIconButton:'));
assert.equal((indicator.match(/Image\(systemName: "checkmark"\)\.offset/g)||[]).length,2);
assert.ok(indicator.includes('.accessibilityLabel(Text("已读"))'));
assert.ok(indicator.includes('.foregroundStyle(.blue)'));
console.log('PASS: authenticated event, monotonic ACK/history, privacy/visibility and accessible double-check integration guards (source only)');
JS
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
    App/Models.swift App/IncomingMessagePersistence.swift scripts/ReadReceiptRegression.swift -o "$test_dir/read-receipts"
"$test_dir/read-receipts" -current_user_id fixture-owner
printf 'Read receipt fixture artifacts: %s\n' "$test_dir"
