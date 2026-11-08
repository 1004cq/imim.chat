#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-chat-search.XXXXXX)
sed -n '/^\/\/ MARK: - Chat search projection/,/^\/\/ MARK: - End chat search projection/p' App/ChatSettingsView.swift > "$test_dir/Projection.swift"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
    App/Models.swift App/AppLocalization.swift App/IncomingMessagePersistence.swift \
    "$test_dir/Projection.swift" scripts/ChatSearchRegression.swift -o "$test_dir/chat-search"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcstringstool compile --output-directory "$test_dir" App/Localizable.xcstrings
"$test_dir/chat-search" -current_user_id fixture-owner
printf 'Chat search fixture artifacts: %s\n' "$test_dir"
