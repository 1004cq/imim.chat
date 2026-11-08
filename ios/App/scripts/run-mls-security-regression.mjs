// Production read-only MLS metadata method with synthetic storage only.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(root, 'App/MLSGroupManager.swift'), 'utf8');
function declaration(marker) {
  const start = source.indexOf(marker); assert.ok(start >= 0, marker);
  let end = source.indexOf('{', start) + 1, depth = 1;
  while (depth && end < source.length) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
  return source.slice(start, end).replace(/^private /, '');
}
const types = ['private struct MLSStoredEpoch:', 'private struct MLSLocalStore:',
  'struct MLSGroupSecurityInfo:', 'enum MLSGroupSecurityError:', 'struct IMIMGroupVerification:'].map(declaration).join('\n');
const method = declaration('func securityInfo(').replaceAll('UserDefaults.standard', 'fixtureDefaults');
assert.ok(!/loadOrCreateStore|prepareGroup|persistStore|APIClient|MLSKeychain\.save|currentKeyPackage|P256/.test(method));
assert.ok(!/\bstore\s*=/.test(method), 'Metadata read must not switch the active actor store');
const fixture = String.raw`
import Foundation
import CryptoKit
let domain = "imim.mls-security-fixture." + UUID().uuidString
@MainActor let fixtureDefaults = UserDefaults(suiteName: domain)!
enum Failure: Error { case locked }
@MainActor enum MLSKeychain {
 static var data: Data?, reads = 0, fail = false
 static func load(service: String, account: String) throws -> Data? {
  reads += 1; if fail { throw Failure.locked }; return data
 }
}
@MainActor final class FixtureManager {
 let keychainService = "synthetic-only"
 var store: MLSLocalStore?
 var deletedAccounts = Set<String>()
`;
const checks = String.raw`
}
@main struct Regression {
 @MainActor static func main() throws {
  defer { fixtureDefaults.removePersistentDomain(forName: domain) }
  fixtureDefaults.set("owner", forKey: "current_user_id")
  var checks = 0
  func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
  func rejects(_ action: () throws -> MLSGroupSecurityInfo) {
   do { _ = try action(); preconditionFailure("expected rejection") } catch { checks += 1 }
  }
  let m = FixtureManager()
  let missing = try m.securityInfo(groupId: "g", userId: "owner")
  check(!missing.hasLocalState && missing.epoch == nil && missing.memberCount == nil, "missing keys are explicit, not fake zero values")
  check(m.store == nil && MLSKeychain.data == nil, "no creation on missing storage")
  func epoch(_ number: Int = 7, groupID: String = "g") -> MLSStoredEpoch {
   .init(epoch: number, groupId: groupID, groupSecret: "synthetic-secret",
    applicationSecret: "synthetic-secret", confirmationKey: "synthetic-secret",
    membershipKey: "synthetic-secret", initSecret: "synthetic-secret", myLeafIndex: 1,
    members: ["owner": 1, "peer": 3], createdAt: 12_000)
  }
  func stored(_ owner: String = "owner", value: MLSStoredEpoch = epoch()) -> MLSLocalStore {
   .init(userId: owner, identityPrivateKey: "synthetic-private", leafPrivateKey: "synthetic-private",
    initPrivateKey: "synthetic-private", epochs: ["g": value], generations: ["g": 9])
  }
  let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
  let bytes = try encoder.encode(stored())
  MLSKeychain.data = bytes
  let ready = try m.securityInfo(groupId: "g", userId: "owner")
  check(ready.hasLocalState && ready.epoch == 7 && ready.memberCount == 2, "real saved epoch and local membership count")
  check(ready.leafIndex == 1 && ready.generation == 9 && ready.importedAt == 12_000, "real local metadata")
  check(m.store == nil && MLSKeychain.data == bytes, "read neither caches nor writes private store")
  let labels = Set(Mirror(reflecting: ready).children.compactMap(\.label))
  check(labels == Set(["ownerID", "groupID", "epoch", "leafIndex", "memberCount", "generation", "importedAt", "verification"]), "only allowlisted nonsecret fields cross actor boundary")
  let validEpoch = MLSStoredEpoch(epoch: 7, groupId: "g",
    groupSecret: Data(repeating: 0x31, count: 32).base64EncodedString(),
    applicationSecret: Data(repeating: 0x72, count: 32).base64EncodedString(),
    confirmationKey: "synthetic-unused", membershipKey: "synthetic-unused", initSecret: "synthetic-unused",
    myLeafIndex: 1, members: ["owner": 1, "peer": 3], createdAt: 12_000)
  m.store = stored(value: validEpoch)
  let beforeComparison = try encoder.encode(m.store!)
  let comparable = try m.securityInfo(groupId: "g", userId: "owner")
  check(comparable.verification != nil && comparable.verification!.matches(comparable.verification!.qrPayload), "valid saved state produces a usable derived QR")
  check(try encoder.encode(m.store!) == beforeComparison && MLSKeychain.data == bytes, "comparison does not mutate keys or generations")
  check(ready.verification == nil, "invalid source key material does not fabricate a code")
  m.store = nil
  let unknownGroup = try m.securityInfo(groupId: "another-group", userId: "owner")
  check(!unknownGroup.hasLocalState, "no phantom unrelated group state")
  m.store = stored("other-owner")
  let cachedBefore = try encoder.encode(m.store!)
  _ = try m.securityInfo(groupId: "g", userId: "owner")
  check(try encoder.encode(m.store!) == cachedBefore, "metadata read cannot switch account store")
  MLSKeychain.data = Data("broken".utf8)
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  MLSKeychain.data = try encoder.encode(stored("wrong-owner"))
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  MLSKeychain.fail = true
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  MLSKeychain.fail = false
  m.store = stored()
  let readsBeforeCache = MLSKeychain.reads
  _ = try m.securityInfo(groupId: "g", userId: "owner")
  check(MLSKeychain.reads == readsBeforeCache && m.store?.generations["g"] == 9, "cached read does not advance sending generation")
  m.store!.generations["g"] = 10
  check(try m.securityInfo(groupId: "g", userId: "owner").generation == 10, "refresh sees committed local update")
  m.store = stored(value: epoch(-1))
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  m.store = stored(value: epoch(groupID: "mismatched"))
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  m.store = stored(value: epoch(0))
  check(try m.securityInfo(groupId: "g", userId: "owner").epoch == 0, "epoch zero is valid, not missing")
  m.store!.generations["g"] = -1
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  fixtureDefaults.set("switched-owner", forKey: "current_user_id")
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  fixtureDefaults.set("owner", forKey: "current_user_id")
  m.deletedAccounts.insert("owner")
  rejects { try m.securityInfo(groupId: "g", userId: "owner") }
  print("PASS: \(checks) production MLS security metadata assertions; no real Keychain, keys, network, account data or group mutation")
 }
}
`;
const directory = mkdtempSync(path.join(tmpdir(), 'imim-mls-security-'));
const swift = path.join(directory, 'Regression.swift'), binary = path.join(directory, 'Regression');
writeFileSync(swift, types + '\n' + fixture + method + checks);
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library', swift, '-o', binary],
  {stdio:'inherit', env:{...process.env, DEVELOPER_DIR:'/Applications/Xcode.app/Contents/Developer'}});
if (build.status !== 0) process.exit(build.status ?? 1);
const run = spawnSync(binary, [], {stdio:'inherit'});
if (run.status !== 0) process.exit(run.status ?? 1);
const view = readFileSync(path.join(root, 'App/ChatDetailView.swift'), 'utf8');
assert.ok(view.includes('GroupEncryptionInfo(groupID: chat.chatId, groupName: chat.name)'));
const group = view.slice(view.indexOf('private struct GroupEncryptionInfo:'), view.indexOf('private struct ConversationEncryptionInfo:'));
assert.ok(group.includes('MLSGroupManager.shared.securityInfo('));
assert.ok(group.includes('.task(id: loadGate.ticket)') && group.includes('loadGate.finish(ticket)'));
assert.ok(group.includes('本机尚未同步') && group.includes('value.hasLocalState'));
assert.ok(!/setPeerVerified|safetyNumber|prepareGroup\(|hasState\(|resetSession|APIClient|currentKeyPackage/.test(group));
console.log('PASS: group sheet routing, real local metadata, explicit missing state, bounded loading and no private-chat verification or group-join actions');
