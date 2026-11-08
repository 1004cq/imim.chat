#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-release-chat.XXXXXX)
python3 - "$test_dir/Actual.swift" <<'GEN'
from pathlib import Path
import sys
s=Path('App/ChatDetailViewModel.swift').read_text()
helper=s[s.index('// MARK: Release chat concurrency'):s.index('// MARK: End release chat concurrency')]
projection=s[s.index('    private struct MessageSortKey:'):s.index('    func beginReply')]
fullrows=Path('App/ChatsViewModel.swift').read_text(); rows=fullrows.split('    func refresh(')[0]+'}\n'+fullrows[fullrows.index('extension Chat {'):]
base=Path('App/Models.swift').read_text()+Path('App/AppLocalization.swift').read_text()+Path('App/Date+ChatFormatting.swift').read_text()
api=Path('App/APIClient.swift').read_text();base+=api[api.index('enum AIConversation {'):api.index('enum AIConversation {')+api[api.index('enum AIConversation {'):].index('\n}')+2]
stubs="""
enum APIClientError: Error { case server(String) }
@MainActor enum AuthTokenStore { static var shared = Store(); struct Store { var token: String? = "fixture" } }
@MainActor final class E2EEManager {
 static let shared = E2EEManager(); var calls=0; var fail=false
 func synchronizeCurrentUser() async throws { calls += 1; if fail { throw FixtureError.failed } }
}
enum FixtureError: Error { case failed }
"""
Path(sys.argv[1]).write_text(base+helper+stubs+'\n@MainActor final class SortHarness {\n'+projection+'\nfunc sync() async throws { try await synchronizeE2EEIfNeeded() }\n}\n'+rows+Path('scripts/ReleaseChatRegression.swift').read_text())
GEN
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library "$test_dir/Actual.swift" -o "$test_dir/regression"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcstringstool compile --output-directory "$test_dir" App/Localizable.xcstrings
"$test_dir/regression"
