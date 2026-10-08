#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-conversation-presentation.XXXXXX)
node - <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const view = fs.readFileSync('App/ChatsView.swift', 'utf8');
assert.equal((view.match(/viewModel\.conversationRows\(from: chats\)/g) || []).length, 1);
assert.ok(view.includes('let rows = viewModel.conversationRows(from: chats)'));
assert.ok(view.includes('ForEach(rows)'));
assert.ok(view.includes('let chat = row.chat'));
assert.ok(!view.includes('chats.first(where: { $0.chatId == conversation.id })'));
assert.ok(!view.includes('ForEach(conversations)'));
console.log('PASS: single body projection and carried row target source checks');
JS
# Compile production projection/filter/action methods, actual SwiftData models,
# actual localization and date helper. No API, auth, avatar or crypto stubs.
{
    cat App/Models.swift App/AppLocalization.swift App/Date+ChatFormatting.swift
    sed '/^    func refresh(/,$d' App/ChatsViewModel.swift
    sed -n '/^    func delete(_ chat:/,/^    }/p' App/ChatsViewModel.swift
    printf '%s\n' '}'
    sed -n '/^extension Chat {/,/^}/p' App/ChatsViewModel.swift
    cat scripts/ConversationPresentationRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -parse-as-library \
    - -o "$test_dir/ConversationPresentationRegression"
# Use the app's compiled strings, not a mocked Chinese/English lookup.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcstringstool compile \
    --output-directory "$test_dir" App/Localizable.xcstrings
"$test_dir/ConversationPresentationRegression"
