// Execute the production actor with synthetic keys, fake HTTP and an in-memory
// Keychain. Never reads device data, the real Keychain or user defaults.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const original = readFileSync(path.join(root, 'App/MLSGroupManager.swift'), 'utf8');
let production = original.slice(0, original.indexOf('\nprivate enum MLSKeychain'));
const begin = production.indexOf('    private func stableDeviceId()');
const end = production.indexOf('    private func deriveMessageKey(', begin);
assert.ok(begin >= 0 && end > begin);
production = production.slice(0, begin) + '    private func stableDeviceId() -> String { "synthetic-device" }\n' + production.slice(end);
const fixture = String.raw`
enum FixtureError: Error { case failed }
enum MLSKeychain {
 static var bytes: Data?, failSave = false
 static func load(service: String, account: String) throws -> Data? { bytes }
 static func save(_ value: Data, service: String, account: String) throws {
  if failSave { throw FixtureError.failed }; bytes = value
 }
}
struct MLSRecoveryStatus { let epoch: Int }
struct MLSDeviceWelcomeResponse { let ready: Bool; let requestId: String?; let welcome: MLSWelcome?; let senderIdentityKey: String? }
actor APIClient {
 static let shared = APIClient()
 var epoch = 3, response = MLSDeviceWelcomeResponse(ready: false, requestId: nil, welcome: nil, senderIdentityKey: nil)
 var onFetch: (() async throws -> Void)?
 func configure(_ welcome: MLSWelcome, _ sender: String, epoch: Int) {
  self.epoch = epoch; response = .init(ready: true, requestId: "synthetic-request", welcome: welcome, senderIdentityKey: sender)
 }
 func fetchMLSRecoveryStatus(groupId: String) async throws -> MLSRecoveryStatus { .init(epoch: epoch) }
 func fetchMLSDeviceWelcome(groupId: String, deviceId: String) async throws -> MLSDeviceWelcomeResponse {
  if let action = onFetch { onFetch = nil; try await action() }; return response
 }
 func requestMLSDeviceJoin(groupId: String, deviceId: String, keyPackage: MLSKeyPackage) async throws -> Bool { true }
 func acknowledgeMLSDeviceWelcome(requestId: String) async throws {}
 func advanceOnWelcomeFetch(_ welcome: MLSWelcome, _ sender: String, epoch: Int) {
  onFetch = { self.configure(welcome, sender, epoch: epoch) }
 }
 func switchAccountOnFetch(_ manager: MLSGroupManager) { onFetch = { try await manager.fixtureSwitchAccount() } }
}
extension MLSGroupManager {
 func fixtureSwitchAccount() throws { store = nil; MLSKeychain.bytes = nil; try loadOrCreateStore(userId: "other") }
 func fixtureSetup() throws -> MLSKeyPackage {
  try loadOrCreateStore(userId: "owner")
  let secret = Data(repeating: 2, count: 32).base64EncodedString()
  store!.epochs["g"] = .init(epoch: 2, groupId: "g", groupSecret: secret, applicationSecret: secret, confirmationKey: secret, membershipKey: secret, initSecret: secret, myLeafIndex: 0, members: ["owner": 0], createdAt: 0)
  try persistStore(store!)
  return try currentKeyPackage(userId: "owner")!
 }
 func fixtureWelcome(_ kp: MLSKeyPackage, epoch: Int) throws -> (MLSWelcome, String) {
  let sender = P256.KeyAgreement.PrivateKey()
  let target = try P256.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: kp.initKey)!)
  let shared = try sender.sharedSecretFromKeyAgreement(with: target).withUnsafeBytes { Data($0) }
  let key = hkdf(ikm: shared, salt: nil, info: Data("mls-welcome".utf8), length: 32)
  let secret = Data(repeating: UInt8(epoch), count: 32).base64EncodedString()
  let info = MLSWelcomeGroupInfo(groupId: "g", epoch: epoch, groupSecret: secret, applicationSecret: secret, confirmationKey: secret, membershipKey: secret, initSecret: secret, myLeafIndex: 0)
  let payload = try encryptAESGCM(JSONEncoder().encode(info), key: key, aad: Data())
  return (.init(groupId: "g", epoch: epoch, encryptedGroupInfo: payload, leafIndex: 0, treeSnapshot: [], members: ["owner": 0]), sender.publicKey.rawRepresentation.base64EncodedString())
 }
 func fixtureClearEpochs() throws { store!.epochs.removeAll(); try persistStore(store!) }
 func fixtureEpoch() -> Int { store!.epochs["g"]!.epoch }
}
@main struct Regression {
 static func wire(_ value: String) throws -> MLSWireEnvelope { try JSONDecoder().decode(MLSWireEnvelope.self, from: Data(value.utf8)) }
 static func main() async throws {
  let manager = MLSGroupManager(), api = APIClient.shared
  let kp = try await manager.fixtureSetup()
  let old = try wire(await manager.encrypt("synthetic old", groupId: "g", userId: "owner"))
  let (welcome, sender) = try await manager.fixtureWelcome(kp, epoch: 3)
  await api.configure(welcome, sender, epoch: 3)
  let ready = try await manager.prepareGroup(groupId: "g", userId: "owner", waitForWelcome: false)
  precondition(ready)
  let restoredOld = try await manager.decrypt(old, groupId: "g", userId: "owner")
  precondition(restoredOld == "synthetic old")
  let first = try wire(await manager.encrypt("synthetic new", groupId: "g", userId: "owner"))
  precondition(first.epoch == 3 && first.generation == 0)
  _ = try await manager.prepareGroup(groupId: "g", userId: "owner", waitForWelcome: false)
  let second = try wire(await manager.encrypt("synthetic next", groupId: "g", userId: "owner"))
  precondition(second.generation == 1, "Duplicate Welcome must not reset generation")
  let (older, olderSender) = try await manager.fixtureWelcome(kp, epoch: 2)
  await api.configure(older, olderSender, epoch: 3)
  do { _ = try await manager.prepareGroup(groupId: "g", userId: "owner", waitForWelcome: false); preconditionFailure("stale Welcome accepted") } catch {}
  precondition(await manager.fixtureEpoch() == 3)
  let (next, nextSender) = try await manager.fixtureWelcome(kp, epoch: 4)
  await api.configure(next, nextSender, epoch: 4)
  MLSKeychain.failSave = true
  do { _ = try await manager.prepareGroup(groupId: "g", userId: "owner", waitForWelcome: false); preconditionFailure("save failure ignored") } catch {}
  MLSKeychain.failSave = false
  precondition(await manager.fixtureEpoch() == 3)
  _ = try await manager.prepareGroup(groupId: "g", userId: "owner", waitForWelcome: false)
  precondition(await manager.fixtureEpoch() == 4)
  let currentWire = try wire(await manager.encrypt("synthetic realtime", groupId: "g", userId: "owner"))
  let lagging = MLSGroupManager()
  _ = try await lagging.fixtureSetup()
  let realtime = try await lagging.decrypt(currentWire, groupId: "g", userId: "owner")
  precondition(realtime == "synthetic realtime")
  let (racing, racingSender) = try await manager.fixtureWelcome(kp, epoch: 5)
  await api.advanceOnWelcomeFetch(racing, racingSender, epoch: 5)
  do {
   let raced = try await manager.prepareGroup(groupId: "g", userId: "owner", waitForWelcome: false)
   precondition(raced)
  } catch {
   print("REPRODUCED: epoch advances between status and Welcome, valid upgrade rejected:", error)
   exit(1)
  }
  precondition(await manager.fixtureEpoch() == 5)
  let coldWire = try wire(await manager.encrypt("synthetic cold restore", groupId: "g", userId: "owner"))
  try await manager.fixtureClearEpochs()
  let coldRestored = try await manager.decrypt(coldWire, groupId: "g", userId: "owner")
  precondition(coldRestored == "synthetic cold restore")
  await api.switchAccountOnFetch(manager)
  do { _ = try await manager.prepareGroup(groupId: "g", userId: "owner", waitForWelcome: false); preconditionFailure("account switch ignored") } catch {}
  print("PASS: production actor checks new epoch despite existing state; encrypted Welcome upgrade, archived old decryption, duplicate generation safety, stale rejection, in-flight epoch advancement, cold-state restoration, save rollback/retry and account switch; synthetic data only")
 }
}
`;
// Awaited expressions cannot appear inside Swift's synchronous precondition autoclosure.
const adjusted = fixture.replace(/precondition\(await manager.fixtureEpoch\(\) == (\d)\)/g, (_, epoch) => `do { let actual = await manager.fixtureEpoch(); precondition(actual == ${epoch}) }`);
const dir = mkdtempSync(path.join(tmpdir(), 'imim-mls-epoch-'));
writeFileSync(path.join(dir, 'Regression.swift'), production + adjusted, {mode: 0o600});
const compile = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', path.join(dir, 'Regression.swift'), '-o', path.join(dir, 'Regression')], {stdio: 'inherit'});
process.exitCode = compile.status === 0 ? spawnSync(path.join(dir, 'Regression'), [], {stdio: 'inherit'}).status ?? 1 : compile.status ?? 1;
