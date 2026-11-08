#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-friend-link-regression.XXXXXX)
{
    printf '%s\n' 'import Foundation'
    sed -n '/^enum FriendLink {/,/^}/p' App/ProxySession.swift
    cat scripts/FriendLinkRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library - -o "$test_dir/FriendLinks"
"$test_dir/FriendLinks"
# Navigation bindings are source checks, not a substitute for device lifecycle tests.
node - <<'JS'
const fs = require('node:fs');
const assert = require('node:assert/strict');
const routing = fs.readFileSync('App/ProxySettingsView.swift', 'utf8');
const qr = fs.readFileSync('App/ChatsView.swift', 'utf8');
const friend = fs.readFileSync('App/AddFriendView.swift', 'utf8');
assert.ok(routing.includes('.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)'));
assert.ok(routing.includes('.onOpenURL { url in _ = route(url) }'));
assert.ok(routing.includes('authSession.isAuthenticated, let ownerID = authSession.currentUser?.id'));
assert.ok(routing.includes('!appLock.isLocked else { return }'));
assert.ok(routing.includes('AddFriendView(initialAccount: userID, linkedUserID: userID)'));
assert.ok(routing.includes('pending = .proxy(try ProxyImport.parse(url))'));
assert.ok(routing.includes('route(url) ? .handled : .systemAction'));
assert.ok(qr.includes('return FriendLink.userID(from: url)'));
assert.ok(friend.includes('FriendLink.validUserID(normalizedAccount) != nil'));
assert.ok(friend.includes('result.filter { $0.id == linkedUserID }'));
console.log('PASS: 10 friend routing, authentication, lock, proxy, identity and QR source guards');
JS
