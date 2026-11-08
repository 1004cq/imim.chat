#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-call-history.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
    App/Models.swift App/IncomingMessagePersistence.swift scripts/CallHistoryRegression.swift \
    -o "$test_dir/call-history"
"$test_dir/call-history" "$test_dir/history.store"
printf 'Call history fixture artifacts: %s\n' "$test_dir"
