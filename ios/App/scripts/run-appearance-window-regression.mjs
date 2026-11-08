// Production window synchronization code, compiled with deterministic UIKit/
// main-queue doubles. This does not replace physical trait/rendering acceptance.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(root, 'App/DoveTheme.swift'), 'utf8');
const marker = '@MainActor\nfinal class AppWindowAppearanceAnchor:';
const start = source.indexOf(marker); assert.ok(start > 0);
let end = source.indexOf('{', start) + 1, depth = 1;
while (depth && end < source.length) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
const production = source.slice(start, end);
const canvas = source.match(/static func windowCanvas\(isDarkMode: Bool\) -> UIColor \{[^\n]+\}/)?.[0];
assert.ok(canvas);
const fixture = String.raw`
import Foundation
enum UIUserInterfaceStyle { case unspecified, light, dark }
enum UIColor { case black, white }
@MainActor class UIView {
 weak var window: UIWindow?
 var backgroundColor: UIColor?
 func didMoveToWindow() {}
}
@MainActor class UIViewController {
 var overrideUserInterfaceStyle = UIUserInterfaceStyle.unspecified
 var isViewLoaded = true
 private let content = UIView()
 var viewReads = 0
 var view: UIView { viewReads += 1; return content }
 var statusUpdates = 0
 var navigationPath = ["fixture-group"], draft = "synthetic draft"
 func setNeedsStatusBarAppearanceUpdate() { statusUpdates += 1 }
}
@MainActor final class UIWindow {
 var overrideUserInterfaceStyle = UIUserInterfaceStyle.unspecified
 var backgroundColor: UIColor?
 var rootViewController: UIViewController?
}
@MainActor enum DispatchQueue {
 static let main = Queue()
 @MainActor final class Queue {
  var actions: [@MainActor () -> Void] = []
  func async(execute action: @escaping @MainActor () -> Void) { actions.append(action) }
  func flush() { let pending = actions; actions = []; for action in pending { action() } }
 }
}
enum DoveTheme { CANVAS }
`;
const checks = String.raw`
@main struct Regression {
 @MainActor static func main() {
  var count = 0
  func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1 }
  let anchor = AppWindowAppearanceAnchor(), window = UIWindow(), root = UIViewController()
  window.rootViewController = root
  let originalView = root.view
  anchor.updateAppearance(isDarkMode: false)
  check(DispatchQueue.main.actions.count == 1 && window.overrideUserInterfaceStyle == .unspecified, "no synchronous ancestor mutation during SwiftUI update")
  anchor.window = window; anchor.didMoveToWindow()
  check(DispatchQueue.main.actions.count == 1, "attachment and update coalesce")
  DispatchQueue.main.flush()
  check(window.overrideUserInterfaceStyle == .light && root.overrideUserInterfaceStyle == .light, "initial light traits agree")
  check(window.backgroundColor == .white && root.view.backgroundColor == .white, "initial light canvas agrees")
  let other = UIWindow(); other.overrideUserInterfaceStyle = .dark; other.backgroundColor = .black
  anchor.updateAppearance(isDarkMode: true)
  check(window.overrideUserInterfaceStyle == .light, "changes are deferred outside render transaction")
  DispatchQueue.main.flush()
  check(window.overrideUserInterfaceStyle == .dark && root.overrideUserInterfaceStyle == .dark, "light to dark traits agree")
  check(window.backgroundColor == .black && root.view.backgroundColor == .black, "dark canvas covers both window/root")
  check(other.overrideUserInterfaceStyle == .dark && other.backgroundColor == .black, "unrelated window untouched")
  check(window.rootViewController === root && root.view === originalView && root.navigationPath == ["fixture-group"] && root.draft == "synthetic draft", "no root, navigation or draft replacement")
  anchor.updateAppearance(isDarkMode: false); DispatchQueue.main.flush()
  check(window.overrideUserInterfaceStyle == .light && root.overrideUserInterfaceStyle == .light && root.view.backgroundColor == .white, "dark to light agrees")
  let updates = root.statusUpdates
  anchor.updateAppearance(isDarkMode: false); DispatchQueue.main.flush()
  check(root.statusUpdates == updates, "unchanged style cannot create a status/render feedback loop")
  anchor.updateAppearance(isDarkMode: true); anchor.updateAppearance(isDarkMode: false); anchor.updateAppearance(isDarkMode: true)
  check(DispatchQueue.main.actions.count == 1, "rapid toggles coalesce")
  DispatchQueue.main.flush()
  check(window.overrideUserInterfaceStyle == .dark, "latest preference wins")
  let detachedStyle = window.overrideUserInterfaceStyle
  anchor.updateAppearance(isDarkMode: false); anchor.window = nil; DispatchQueue.main.flush()
  check(window.overrideUserInterfaceStyle == detachedStyle, "detached anchor cannot change old window")
  let later = UIWindow(), unloaded = UIViewController(); unloaded.isViewLoaded = false
  later.rootViewController = unloaded
  anchor.window = later; anchor.didMoveToWindow(); DispatchQueue.main.flush()
  check(later.overrideUserInterfaceStyle == .light && unloaded.overrideUserInterfaceStyle == .light, "late attachment applies pending preference")
  check(unloaded.viewReads == 0, "never force-load a root view")
  check(window.overrideUserInterfaceStyle == detachedStyle, "reattaching only changes actual containing window")
  let status = unloaded.statusUpdates
  var temporary: AppWindowAppearanceAnchor? = AppWindowAppearanceAnchor()
  weak var weakAnchor = temporary
  defer { weakAnchor = nil }
  temporary!.window = later; temporary!.updateAppearance(isDarkMode: true); temporary = nil
  check(weakAnchor == nil, "queued synchronization does not retain removed views")
  DispatchQueue.main.flush()
  check(later.overrideUserInterfaceStyle == .light && unloaded.statusUpdates == status, "late removed callback is inert")
  print("PASS: \(count) production window appearance assertions; synthetic UIKit/main queue, no device data")
 }
}
`;
const directory = mkdtempSync(path.join(tmpdir(), 'imim-appearance-window-'));
const swift = path.join(directory, 'Regression.swift'), binary = path.join(directory, 'Regression');
writeFileSync(swift, fixture.replace('CANVAS', canvas) + '\n' + production + '\n' + checks);
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library', swift, '-o', binary],
  {stdio: 'inherit', env: {...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer'}});
if (build.status !== 0) process.exit(build.status ?? 1);
const run = spawnSync(binary, [], {stdio: 'inherit'});
if (run.status !== 0) process.exit(run.status ?? 1);
const app = readFileSync(path.join(root, 'App/AppEntry.swift'), 'utf8');
const discovery = readFileSync(path.join(root, 'App/DiscoveryView.swift'), 'utf8');
const main = readFileSync(path.join(root, 'App/MainTabView.swift'), 'utf8');
assert.ok(app.includes('AppWindowAppearanceBridge(isDarkMode: isDarkMode)') && app.includes('DoveTheme.windowCanvas(isDarkMode: isDarkMode)'));
assert.ok(!discovery.includes('.preferredColorScheme('), 'retained tab pages must not compete with root appearance');
assert.ok(!/UIApplication|connectedScenes|\.windows|UIAppearance|removeFromSuperview|rootViewController\s*=|makeKey/.test(production));
assert.ok(!/\.id\(isDarkMode|\.id\(.*[Cc]olorScheme|\.ignoresSafeArea\(\.keyboard/.test(app + main));
console.log('PASS: single root authority, explicit canvas, containing-window-only scope, no page identity/navigation reset or keyboard safe-area override');
