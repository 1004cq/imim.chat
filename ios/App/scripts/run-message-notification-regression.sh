#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/imim-notification-regression.XXXXXX)
# Production code is streamed directly to the compiler; no duplicated parser
# or dedupe implementation can drift from the App target.
{
    printf '%s\n' 'import Foundation'
    sed -n '/^private struct PushPayload/,$p' App/PushNotificationManager.swift
    while IFS= read -r line; do
        if [[ "$line" == *INSERT_PRODUCTION_DEDUPE* ]]; then
            sed -n '/^    private func markMessageDisplayed/,/^    }/p' App/PushNotificationManager.swift |
                sed 's/private func markMessageDisplayed/func markMessageDisplayed/'
        else
            printf '%s\n' "$line"
        fi
    done < scripts/MessageNotificationRegression.swift
} | DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library -o "$test_dir/NotificationRegression" -
"$test_dir/NotificationRegression"
