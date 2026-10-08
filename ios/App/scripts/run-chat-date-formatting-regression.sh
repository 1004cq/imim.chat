#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-chat-date-formatting.XXXXXX)
swift_flags=(-O -swift-version 6 -strict-concurrency=complete -D CHAT_DATE_FORMATTING_TESTS -parse-as-library)
if [[ "${CHAT_DATE_TSAN:-0}" == "1" ]]; then
    swift_flags+=(-sanitize=thread)
fi
# Stream existing sources to the compiler; no App data, network, or preferences
# are read/written, and the owner's standard defaults are never modified.
{ cat App/Date+ChatFormatting.swift scripts/ChatDateFormattingRegression.swift; } \
    | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc "${swift_flags[@]}" \
        - -o "$test_dir/ChatDateFormattingRegression"
"$test_dir/ChatDateFormattingRegression"
