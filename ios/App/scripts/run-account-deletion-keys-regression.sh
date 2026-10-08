#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/imim-account-keys-regression.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -D E2EE_REGRESSION_TESTS -parse-as-library App/E2EEEnvelope.swift App/EncryptedMediaStore.swift scripts/AccountDeletionKeysRegression.swift -o "$test_dir/AccountDeletionKeysRegression"
"$test_dir/AccountDeletionKeysRegression"
