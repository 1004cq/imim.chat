#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/imim-sticker-container.XXXXXX)
python3 - "$test_dir/ActualContainer.swift" <<'PY'
from pathlib import Path
import sys
s=Path('App/StickerMedia.swift').read_text()
container=s[s.index('@MainActor\nprivate final class StickerAnimationContainer:'):s.index('private struct LottieStickerView:')]
container=container.replace('LottieAnimationView()', 'FixtureAnimationView()')
fixture='''import UIKit
@MainActor final class FixtureAnimationView: UIView {
 var canvas = CGSize(width:512,height:512)
 override var intrinsicContentSize: CGSize { canvas }
}
'''
tests='''
@main struct Regression {
 @MainActor static func main() {
  var checks = 0
  func check(_ value: Bool, _ note: String) { precondition(value,note); checks += 1 }
  let container = StickerAnimationContainer(frame:.zero)
  check(container.intrinsicContentSize == CGSize(width:UIView.noIntrinsicMetric,height:UIView.noIntrinsicMetric), "original canvas does not size the outer viewport")
  check(container.animationView.intrinsicContentSize == CGSize(width:512,height:512), "fixture reproduces original animation canvas")
  for side in [CGFloat(58),118,176,112,0] {
   container.frame = CGRect(x:0,y:0,width:side,height:side)
   container.setNeedsLayout(); container.layoutIfNeeded()
   check(container.animationView.frame == container.bounds, "player fills actual tile, not original 512-point canvas")
   check(container.animationView.contentMode == .scaleAspectFit, "whole animation stays aspect-fit")
   container.animationView.canvas = CGSize(width:1024,height:256)
   container.animationView.invalidateIntrinsicContentSize()
   container.setNeedsLayout();container.layoutIfNeeded()
   check(container.animationView.frame == container.bounds, "loaded/replaced wide asset cannot expand native player")
  }
  check(!container.isOpaque && container.clipsToBounds, "transparent bounded viewport")
  weak var retained: StickerAnimationContainer?
  do { let disposable = StickerAnimationContainer(frame:.zero);retained=disposable }
  check(retained == nil, "viewport releases without a retention cycle")
  print("PASS: \\(checks) production container checks with real UIKit and a synthetic intrinsic-size player; not Lottie/device visual proof")
 }
}
'''
Path(sys.argv[1]).write_text(fixture+container+tests)
player=s[s.index('private struct LottieStickerView:'):s.index('struct StickerMediaPanel:')]
assert 'func sizeThatFits(_ proposal: ProposedViewSize' in player
assert 'CGSize(width: size, height: size)' in player
assert 'uiView.animationView.pause()' in player and 'coordinator.task?.cancel()' in player
assert 'context.coordinator.load(url: url, isTGS: isTGS, into: view' in player
bitmap=s[s.index('AnimatedImage(url: url, isAnimating:'):s.index('.onGeometryChange(for: Bool.self)')]
assert 'view.contentMode = .scaleAspectFit' in bitmap
assert bitmap.index('.frame(width: size, height: size)') < bitmap.index('.id(replayGeneration)')
asset=s[s.index('@MainActor struct StickerAssetView:'):s.index('private struct StickerReplayTap:')]
assert '.onChange(of: playbackRequest, initial: true)' in asset
assert 'updatePlayback(eligible: request.eligible)' in asset
geometry=asset[asset.index('} action: { visible in'):asset.index('.onAppear')]
assert 'updatePlayback' not in geometry, 'retained geometry action must not read stale scene environment'
assert 'activeScene: scenePhase == .active' in asset
assert 'appearanceGeneration &+= 1' in asset
assert 'appearanceGeneration: appearanceGeneration' in asset
assert 'let eligible = requested && isMounted && isVisible' in asset
assert 'view.backgroundBehavior = .pauseAndRestore' in player

print('PASS: viewport, cleanup and fresh lifecycle reconciliation wiring (source guards)')
PY
sdk=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -O -swift-version 5 -parse-as-library \
 -target arm64-apple-ios17.6-macabi -sdk "$sdk" \
 -F "$sdk/System/iOSSupport/System/Library/Frameworks" -I "$sdk/System/iOSSupport/usr/include" \
 "$test_dir/ActualContainer.swift" -o "$test_dir/regression"
"$test_dir/regression"
