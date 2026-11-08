#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache_test_dir=$(mktemp -d /private/tmp/imim-panel-cache.XXXXXX)
python3 - "$cache_test_dir/Cache.swift" <<'PYTEST'
from pathlib import Path
import sys
s=Path('App/StickerMedia.swift').read_text()
cache='struct StickerPanelCatalogCache {'+s.split('struct StickerPanelCatalogCache {',1)[1].split('@MainActor private enum StickerPanelMemory',1)[0]
fixture='import Foundation\nstruct StickerPack { let id: String }\n'
tests=r"""@main struct Regression {
 static func main() {
  var cache = StickerPanelCatalogCache()
  let now = Date(timeIntervalSince1970: 1000)
  precondition(cache.packs(for:"a").isEmpty && !cache.isFresh(for:"a",now:now))
  cache.store([StickerPack(id:"duck")],owner:"a",now:now)
  precondition(cache.packs(for:"a").map(\.id) == ["duck"])
  precondition(cache.isFresh(for:"a",now:now.addingTimeInterval(59)))
  precondition(!cache.isFresh(for:"a",now:now.addingTimeInterval(60)))
  precondition(!cache.isFresh(for:"a",now:now.addingTimeInterval(-1)))
  precondition(cache.packs(for:"b").isEmpty && !cache.isFresh(for:"b",now:now))
  precondition(cache.packs(for:"a").count == 1, "stale data remains available for first paint")
  cache.store([StickerPack(id:"dino")],owner:"b",now:now)
  precondition(cache.packs(for:"a").isEmpty && cache.packs(for:"b").map(\.id)==["dino"])
  cache.store([],owner:"b",now:now)
  precondition(cache.packs(for:"b").isEmpty && cache.isFresh(for:"b",now:now))
  print("PASS: actual panel metadata cache cold/warm/expiry/clock rollback/account isolation/replacement/empty catalog checks")
 }
}
"""
Path(sys.argv[1]).write_text(fixture+cache+tests)
PYTEST
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -parse-as-library "$cache_test_dir/Cache.swift" -o "$cache_test_dir/regression"
"$cache_test_dir/regression"
