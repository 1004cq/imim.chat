// Production store-loading policy with synthetic in-memory Keychain responses.
// Never reads the user's Keychain, device, messages, credentials or group keys.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(app, 'App/MLSGroupManager.swift'), 'utf8');
function declaration(marker) {
  const start = source.indexOf(marker);
  assert.ok(start >= 0, marker);
  let end = source.indexOf('{', start) + 1, depth = 1;
  while (depth && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  return source.slice(start, end).replace(/^private /, '');
}
const types = ['private struct MLSStoredEpoch:', 'private struct MLSLocalStore:', 'enum MLSGroupError:']
  .map(declaration).join('\n');
const methods = ['private func loadOrCreateStore(', 'private func persistStore(']
  .map(declaration).join('\n');
assert.ok(!methods.includes('try? MLSKeychain.load'));
assert.ok(source.includes('status == errSecSuccess, let data = result as? Data'));

const harness = String.raw`
import Foundation
import CryptoKit
enum FixtureFailure: Error { case unavailable, saveFailed }
enum MLSKeychain {
 static var data: Data?, readFails = false, saveFails = false, reads = 0, writes = 0
 static func reset(_ value: Data? = nil) { data = value; readFails = false; saveFails = false; reads = 0; writes = 0 }
 static func load(service: String, account: String) throws -> Data? {
  reads += 1
  if readFails { throw FixtureFailure.unavailable }
  return data
 }
 static func save(_ value: Data, service: String, account: String) throws {
  writes += 1
  if saveFails { throw FixtureFailure.saveFailed }
  data = value
 }
}
final class FixtureManager {
 let keychainService = "synthetic-only"
 var deletedAccounts = Set<String>()
 var store: MLSLocalStore?
`;
const checks = String.raw`
}
@main struct Regression {
 static func rejects(_ operation: () throws -> Void) {
  do { try operation(); preconditionFailure("expected fail-closed error") } catch {}
 }
 static func main() throws {
  MLSKeychain.reset()
  let first = FixtureManager()
  try first.loadOrCreateStore(userId: "synthetic-owner")
  precondition(MLSKeychain.writes == 1 && first.store?.userId == "synthetic-owner")
  let saved = MLSKeychain.data!
  let firstIdentity = first.store!.identityPrivateKey
  try first.loadOrCreateStore(userId: "synthetic-owner")
  precondition(MLSKeychain.reads == 1 && MLSKeychain.writes == 1)

  MLSKeychain.reset(saved)
  let restored = FixtureManager()
  try restored.loadOrCreateStore(userId: "synthetic-owner")
  precondition(restored.store?.identityPrivateKey == firstIdentity && MLSKeychain.writes == 0)

  MLSKeychain.reset(saved); MLSKeychain.readFails = true
  let unavailable = FixtureManager()
  rejects { try unavailable.loadOrCreateStore(userId: "synthetic-owner") }
  precondition(unavailable.store == nil && MLSKeychain.data == saved && MLSKeychain.writes == 0)
  MLSKeychain.readFails = false
  try unavailable.loadOrCreateStore(userId: "synthetic-owner")
  precondition(unavailable.store?.identityPrivateKey == firstIdentity && MLSKeychain.writes == 0)

  let corrupt = Data("unreadable existing record".utf8)
  MLSKeychain.reset(corrupt)
  let invalid = FixtureManager()
  rejects { try invalid.loadOrCreateStore(userId: "synthetic-owner") }
  precondition(invalid.store == nil && MLSKeychain.data == corrupt && MLSKeychain.writes == 0)

  MLSKeychain.reset(saved)
  let wrongOwner = FixtureManager()
  rejects { try wrongOwner.loadOrCreateStore(userId: "different-owner") }
  precondition(wrongOwner.store == nil && MLSKeychain.data == saved && MLSKeychain.writes == 0)

  MLSKeychain.reset(); MLSKeychain.saveFails = true
  let failedSave = FixtureManager()
  rejects { try failedSave.loadOrCreateStore(userId: "synthetic-owner") }
  precondition(failedSave.store == nil && MLSKeychain.data == nil)
  MLSKeychain.saveFails = false
  try failedSave.loadOrCreateStore(userId: "synthetic-owner")
  precondition(failedSave.store != nil && MLSKeychain.data != nil && MLSKeychain.writes == 2)

  MLSKeychain.reset(saved)
  let deleted = FixtureManager(); deleted.deletedAccounts.insert("synthetic-owner")
  rejects { try deleted.loadOrCreateStore(userId: "synthetic-owner") }
  precondition(MLSKeychain.reads == 0 && MLSKeychain.writes == 0)
  print("PASS: production MLS store loading preserves existing keys on unavailable/corrupt/wrong-owner records, caches only after successful persistence, restores original identity after retry; synthetic Keychain only")
 }
}
`;
const directory = mkdtempSync(path.join(tmpdir(), 'imim-mls-store-'));
const file = path.join(directory, 'Regression.swift');
const binary = path.join(directory, 'Regression');
writeFileSync(file, harness + methods + '\n' + checks + '\n' + types, {mode: 0o600});
const compile = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', file, '-o', binary], {stdio: 'inherit'});
if (compile.status !== 0) process.exitCode = compile.status ?? 1;
else process.exitCode = spawnSync(binary, [], {stdio: 'inherit'}).status ?? 1;
