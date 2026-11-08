// Execute the production sheet's reload/deadline methods against synthetic reads.
// No UIKit, device, Keychain, real auth, messages or server access.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(app, 'App/ChatDetailView.swift'), 'utf8');
const gate = source.slice(source.indexOf('private struct SecurityInfoLoadGate'), source.indexOf('private struct GroupEncryptionInfo:')).replace('private struct', 'struct');
const methods = source.slice(source.indexOf('    @MainActor private func expireRead('), source.indexOf('    @MainActor private func setVerified(')).replaceAll('@MainActor private func', 'func');
assert.ok(gate.includes('candidate == ticket, isLoading'));
assert.ok(methods.includes('loadGate.finish(ticket)'));
assert.ok(source.includes('.task(id: loadGate.ticket)'));
assert.ok(source.includes('Task.sleep(for: .seconds(8))'));
const harness = String.raw`
import Foundation
struct E2EEPeerSecurityInfo {
 let ownerID: String, peerID: String, binding: String, qrPayload: String
}
enum E2EESecurityInfoError: Error { case identityChanged, noSession, accountChanged, unavailable }
enum Phase { case active, inactive, background }
@MainActor final class AuthTokenStore { static let shared = AuthTokenStore(); var token: String? = "synthetic-token" }
@MainActor final class E2EEManager {
 static let shared = E2EEManager()
 var mode = "success"
 var waiters: [CheckedContinuation<E2EEPeerSecurityInfo, Error>] = []
 func peerSecurityInfo(ownerID: String, peerID: String) async throws -> E2EEPeerSecurityInfo {
  if mode == "hold" { return try await withCheckedThrowingContinuation { waiters.append($0) } }
  if mode == "missing" { throw E2EESecurityInfoError.noSession }
  if mode == "changed" { throw E2EESecurityInfoError.identityChanged }
  return .init(ownerID: ownerID, peerID: peerID, binding: "synthetic-binding", qrPayload: "synthetic-QR")
 }
}
enum QRCodeGenerator { static func makeImage(from payload: String) -> String? { payload } }
@MainActor final class Fixture {
 var ownerID = "owner", peerID: String? = "peer", scenePhase = Phase.inactive
 var info: E2EEPeerSecurityInfo?, qrImage: String?, loadError: String?, actionMessage: String?
 var confirmingVerification = false, verificationCandidate: String?
 var loadGate = SecurityInfoLoadGate()
`;
const main = String.raw`
}
@main struct Regression {
 @MainActor static func main() async {
  var checks = 0
  func check(_ ok: Bool, _ label: String) { precondition(ok, label); checks += 1 }
  let f = Fixture(), api = E2EEManager.shared
  await f.reload()
  check(f.info != nil && !f.loadGate.isLoading, "initial inactive sheet still loads")
  AuthTokenStore.shared.token = nil
  await f.reload()
  check(f.info == nil && !f.loadGate.isLoading && f.loadError != nil, "missing token ends spinner")
  AuthTokenStore.shared.token = "synthetic-token"
  f.peerID = nil; await f.reload()
  check(f.info == nil && !f.loadGate.isLoading && f.loadError != nil, "missing peer ends spinner")
  f.peerID = "peer"; api.mode = "missing"; await f.reload()
  check(!f.loadGate.isLoading && f.loadError?.contains("加密消息") == true, "absent session is explicit, not manufactured")
  api.mode = "changed"; await f.reload()
  check(!f.loadGate.isLoading && f.loadError?.contains("变化") == true, "identity change visible")
  api.mode = "hold"
  let pending = Task { await f.reload() }
  while api.waiters.isEmpty { await Task.yield() }
  let expiredTicket = f.loadGate.ticket
  f.expireRead(expiredTicket)
  check(!f.loadGate.isLoading && f.loadError?.contains("超时") == true, "deadline exits spinner even if read ignores cancellation")
  api.waiters.removeFirst().resume(returning: .init(ownerID:"owner",peerID:"peer",binding:"late",qrPayload:"late"))
  await pending.value
  check(f.info == nil && f.loadError?.contains("超时") == true, "late success cannot replace timeout")

  let old = Task { await f.reload() }
  while api.waiters.isEmpty { await Task.yield() }
  let oldTicket = f.loadGate.ticket
  let fresh = Task { await f.reload() }
  while api.waiters.count < 2 { await Task.yield() }
  f.expireRead(oldTicket)
  check(f.loadGate.isLoading, "old deadline cannot expire new attempt")
  api.waiters.removeFirst().resume(returning: .init(ownerID:"owner",peerID:"peer",binding:"old",qrPayload:"old"))
  await old.value
  check(f.loadGate.isLoading && f.info == nil, "old completion cannot finish new attempt")
  api.waiters.removeFirst().resume(returning: .init(ownerID:"owner",peerID:"peer",binding:"fresh",qrPayload:"fresh"))
  await fresh.value
  check(!f.loadGate.isLoading && f.info?.binding == "fresh" && f.loadError == nil, "retry can display data")

  let switchAccount = Task { await f.reload() }
  while api.waiters.isEmpty { await Task.yield() }
  f.ownerID = "another-owner"
  api.waiters.removeFirst().resume(returning: .init(ownerID:"owner",peerID:"peer",binding:"wrong-account",qrPayload:"wrong-account"))
  await switchAccount.value
  check(!f.loadGate.isLoading && f.info == nil && f.loadError != nil, "account switch rejects stale data and ends spinner")
  f.ownerID = "owner"
  let cancelled = Task { await f.reload() }
  while api.waiters.isEmpty { await Task.yield() }
  cancelled.cancel()
  api.waiters.removeFirst().resume(returning: .init(ownerID:"owner",peerID:"peer",binding:"cancelled",qrPayload:"cancelled"))
  await cancelled.value
  check(!f.loadGate.isLoading && f.info == nil, "cancelled read cannot publish")
  print("PASS: \(checks) production security-sheet load/deadline assertions; inactive scene, missing context, no-session, timeout, retry, stale result, account switch and cancellation")
 }
}
`;
const directory = mkdtempSync(path.join(tmpdir(), 'imim-security-load-'));
const swift = path.join(directory, 'Regression.swift'), binary = path.join(directory, 'Regression');
writeFileSync(swift, harness.replace('@MainActor final class Fixture {', gate + '\n@MainActor final class Fixture {') + methods + main);
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library', swift, '-o', binary],
  {stdio:'inherit',env:{...process.env,DEVELOPER_DIR:'/Applications/Xcode.app/Contents/Developer'}});
if (build.status !== 0) process.exit(build.status ?? 1);
const result = spawnSync(binary, [], {stdio:'inherit'});
if (result.status !== 0) process.exit(result.status ?? 1);
