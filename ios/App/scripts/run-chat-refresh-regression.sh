#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-chat-refresh.XXXXXX)
python3 - "$test_dir/ActualRefresh.swift" <<'PY'
from pathlib import Path
import sys
s=Path('App/ChatsViewModel.swift').read_text()
refresh=s[s.index('    func refresh(chats:'):s.index('    func delete(_ chat:')]
fixture=Path('scripts/ChatRefreshRegression.swift').read_text()
assert 'private var activeRefreshID: UUID?' in s
Path(sys.argv[1]).write_text(fixture.replace('// ACTUAL_REFRESH',refresh))
PY
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -swift-version 5 -parse-as-library "$test_dir/ActualRefresh.swift" -o "$test_dir/regression"
"$test_dir/regression"
