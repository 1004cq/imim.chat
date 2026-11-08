#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-sticker-activity.XXXXXX)
python3 - "$test_dir/Activity.swift" <<'INNER'
from pathlib import Path
import sys
s=Path('App/StickerMedia.swift').read_text()
a=s.index('@MainActor\nprivate final class StickerApplicationActivity:')
b=s.index('@MainActor struct StickerAssetView:',a)
source='import UIKit\nimport Combine\n'+s[a:b]
tests=r"""
@main struct Regression {
 @MainActor static func main() {
  let center = NotificationCenter()
  var active = false
  var checks = 0
  func check(_ result: Bool, _ label: String) { precondition(result,label);checks += 1 }
  var monitor: StickerApplicationActivity? = StickerApplicationActivity(center:center, readActive:{active})
  check(monitor?.isActive == false, "initial UIKit inactive state pauses")
  active=true
  center.post(name:UIApplication.didBecomeActiveNotification,object:nil)
  check(monitor?.isActive == true, "foreground resumes independently of stale SwiftUI phase")
  center.post(name:UIApplication.willResignActiveNotification,object:nil)
  check(monitor?.isActive == false, "will-resign pauses before application state changes")
  active=false
  center.post(name:UIApplication.didEnterBackgroundNotification,object:nil)
  check(monitor?.isActive == false, "background stays paused")
  center.post(name:UIApplication.didBecomeActiveNotification,object:nil)
  check(monitor?.isActive == false, "stale activation event cannot enable a background app")
  for _ in 0..<20 {
   active=true
   monitor?.refresh()
   check(monitor?.isActive == true,"chat reappearance refreshes current activity")
   center.post(name:UIApplication.willResignActiveNotification,object:nil)
   check(monitor?.isActive == false,"each departure pauses")
   active=false
   center.post(name:UIApplication.didEnterBackgroundNotification,object:nil)
   active=true
   center.post(name:UIApplication.didBecomeActiveNotification,object:nil)
   check(monitor?.isActive == true,"each foreground return resumes")
  }
  weak var released=monitor
  monitor=nil
  check(released == nil,"observers do not retain activity owner")
  center.post(name:UIApplication.didBecomeActiveNotification,object:nil)
  print("PASS: \(checks) actual UIKit notification lifecycle checks; not physical animation proof")
 }
}
"""
Path(sys.argv[1]).write_text(source+tests)
asset=s[s.index('@MainActor struct StickerAssetView:'):s.index('private struct StickerReplayTap:')]
assert 'activeScene: applicationActivity.isActive' in asset
assert '@Environment(\\.scenePhase)' not in asset
assert 'reduceMotion: reduceMotion, lowPower: lowPower, failed: hasFailed' in asset
assert 'applicationActivity.refresh()' in asset
INNER
sdk=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -swift-version 5 -parse-as-library \
 -target arm64-apple-ios17.6-macabi -sdk "$sdk" \
 -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include" \
 "$test_dir/Activity.swift" -o "$test_dir/regression"
"$test_dir/regression"
