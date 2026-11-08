// Cross-language fixtures only: no actual account, Keychain, browser DB or API.
import assert from 'node:assert/strict';
import {readFileSync, mkdtempSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {stripTypeScriptTypes, createRequire} from 'node:module';
import {createHmac, createHash} from 'node:crypto';
import {runInNewContext} from 'node:vm';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const web = process.argv[2];
assert.ok(web, 'Pass cqim-app checkout path for cross-language comparison');
const source = readFileSync(path.join(root, 'App/MLSGroupManager.swift'), 'utf8');
const start = source.indexOf('struct IMIMGroupVerification:');
let end = source.indexOf('{', start) + 1, depth = 1;
while (depth && end < source.length) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
const swiftType = source.slice(start, end);
const ts = readFileSync(path.join(web, 'client/src/lib/e2ee/MLSGroupVerification.ts'), 'utf8');
const api = await import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes(ts)).toString('base64'));
const secret = Buffer.alloc(32, 0x31).toString('base64'), application = Buffer.alloc(32, 0x72).toString('base64');
const base = {groupId: 'fixture-group', epoch: 4, members: {alice: 0, bob: 2}, groupSecret: secret, applicationSecret: application};
const fixtures = [base, {...base, members: {bob: 2, alice: 0}}, {...base, groupId: '群😀', members: {'é': 3, '😀': 7, '中': 2}},
  {...base, epoch: 0}, {...base, epoch: Number.MAX_SAFE_INTEGER}, {...base, groupId: 'ab\0c'},
  {...base, epoch: 5}, {...base, groupId: 'other-group'}, {...base, members: {alice: 0, bob: 3}},
  {...base, groupSecret: Buffer.alloc(32, 0x32).toString('base64')},
  {...base, applicationSecret: Buffer.alloc(32, 0x73).toString('base64')},
  {...base, groupSecret: ''}, {...base, applicationSecret: 'bad'}, {...base, epoch: -1},
  {...base, members: {}}, {...base, members: {alice: 0, bob: 0}}, {...base, members: {alice: -1}},
  {...base, groupId: 'e\u0301'}, {...base, groupSecret: secret.trimEnd().replace(/=$/, '')},
  {...base, groupId: 'g'.repeat(257)}, {...base, groupId: '😀'.repeat(65)},
];
const values = await Promise.all(fixtures.map(api.makeGroupVerification));
assert.ok(values[0]);
assert.deepEqual(values[0], values[1], 'member order does not affect comparison');
for (let i = 6; i <= 10; i++) assert.notEqual(values[i].authenticator, values[0].authenticator, 'group/epoch/member/keys bind code');
for (let i = 11; i < fixtures.length; i++) assert.equal(values[i], null, 'invalid input never produces a placeholder');
// Independent Node primitive oracle and binary encoding, not a port of either UI.
const chunks = [Buffer.from('imim/group-epoch-comparison/v1\0')];
const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
const u64 = n => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b; };
const str = s => { const b = Buffer.from(s); return Buffer.concat([u32(b.length), b]); };
chunks.push(str(base.groupId), u64(4), createHash('sha256').update(Buffer.from(application, 'base64')).digest(), u32(2), str('alice'), u64(0), str('bob'), u64(2));
const golden = createHmac('sha256', Buffer.from(secret, 'base64')).update(Buffer.concat(chunks)).digest('hex');
assert.equal(values[0].authenticator, golden);
const qr = api.groupVerificationQR(values[0]);
const bad = [qr.replace('"v":1', '"v":2'), qr.replace('"epoch":4', '"epoch":5'),
  qr.replace('fixture-group', 'other-group'), qr.replace(golden, '0'.repeat(64)),
  qr.replace('imim-group-epoch-comparison', 'imim-safety-number'), qr.replace('"v":1', '"v":true'),
  JSON.stringify({...JSON.parse(qr), unknown: true}), 'https://app.imim.chat/user/0', 'bad-json', 'a'.repeat(4097)];
assert.ok(api.matchesGroupVerification(values[0], qr));
for (const raw of bad) assert.equal(api.matchesGroupVerification(values[0], raw), false);
const fixtureSwift = String.raw`
import Foundation
import CryptoKit
struct Fixture: Decodable { let groupId: String; let epoch: Int; let members: [String: Int]; let groupSecret: String; let applicationSecret: String }
struct Request: Decodable { let fixtures: [Fixture]; let candidates: [String] }
struct Output: Encodable { let authenticator: String?; let number: String?; let qr: String?; let matches: [Bool] }
@main struct Regression {
 static func main() throws {
  let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
  let result = request.fixtures.map { f -> Output in
   let code = IMIMGroupVerification.make(groupID: f.groupId, epoch: f.epoch, members: f.members, groupSecret: f.groupSecret, applicationSecret: f.applicationSecret)
   return Output(authenticator: code?.authenticator, number: code?.number, qr: code?.qrPayload, matches: request.candidates.map { code?.matches($0) ?? false })
  }
  FileHandle.standardOutput.write(try JSONEncoder().encode(result))
 }
}
`;
const directory = mkdtempSync(path.join(tmpdir(), 'imim-group-comparison-'));
const swift = path.join(directory, 'Regression.swift'), binary = path.join(directory, 'Regression');
writeFileSync(swift, swiftType + '\n' + fixtureSwift);
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library', swift, '-o', binary],
  {stdio: 'inherit', env: {...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer'}});
assert.equal(build.status, 0, 'production Swift comparison compiles');
const run = spawnSync(binary, [], {input: JSON.stringify({fixtures, candidates: [qr, ...bad]}), encoding: 'utf8'});
assert.equal(run.status, 0, run.stderr);
const native = JSON.parse(run.stdout);
for (let i = 0; i < fixtures.length; i++) {
  assert.equal(native[i].authenticator ?? null, values[i]?.authenticator ?? null, 'Swift/Web MAC identical');
  assert.equal(native[i].number ?? null, values[i] ? api.groupVerificationNumber(values[i]) : null, 'Swift/Web digits identical');
  if (native[i].qr) assert.deepEqual(JSON.parse(native[i].qr), JSON.parse(api.groupVerificationQR(values[i])));
  assert.deepEqual(native[i].matches, [qr, ...bad].map(raw => values[i] ? api.matchesGroupVerification(values[i], raw) : false));
}
// Real QR encoder/decoder roundtrip entirely offline with synthetic payload.
const require = createRequire(path.join(web, 'package.json'));
// Execute the production manager's read method against a synthetic store.
const tsCompiler = require('typescript');
const managerText = readFileSync(path.join(web, 'client/src/lib/e2ee/MLSGroupManager.ts'), 'utf8');
const managerAST = tsCompiler.createSourceFile('Manager.ts', managerText, tsCompiler.ScriptTarget.Latest, true);
const managerClass = managerAST.statements.find(node => tsCompiler.isClassDeclaration(node) && node.name?.text === 'MLSGroupManager');
const method = managerClass.members.find(node => node.name?.getText(managerAST) === 'getGroupSecuritySnapshot').getText(managerAST);
assert.ok(!/getEpochState\(|epochCache|generationCounters|save|persist|recover|prepare|upload|fetch|localKeys/.test(method.replaceAll('this.store.getEpochState(', 'read(')));
const FixtureManager = runInNewContext(stripTypeScriptTypes('class FixtureManager { ' + method + ' }; FixtureManager'), {makeGroupVerification: api.makeGroupVerification});
const manager = new FixtureManager(); manager.userId = 'alice'; manager._initialized = true;
let durable = {...base, myLeafIndex: 0, createdAt: 1234}, reads = 0;
manager.store = {getEpochState: async () => { reads++; return durable; }};
const metadata = await manager.getGroupSecuritySnapshot(base.groupId);
assert.equal(metadata.verification.authenticator, golden);
assert.equal(metadata.memberCount, 2);
assert.ok(!JSON.stringify(metadata).includes(secret) && !JSON.stringify(metadata).includes(application));
assert.equal(reads, 2, 'revalidate durable snapshot after async MAC');
manager._initialized = false;
assert.equal(await manager.getGroupSecuritySnapshot(base.groupId), null);
assert.equal(reads, 2, 'never initialize keys for UI');
manager._initialized = true; durable = null;
assert.equal(await manager.getGroupSecuritySnapshot(base.groupId), null);
durable = {...base, myLeafIndex: 9, createdAt: 1234};
assert.equal((await manager.getGroupSecuritySnapshot(base.groupId)).verification, null, 'inconsistent local membership cannot verify');
durable = {...base, myLeafIndex: 0, createdAt: 1234};
manager.store.getEpochState = async () => { manager.userId = 'another-owner'; return durable; };
assert.equal(await manager.getGroupSecuritySnapshot(base.groupId), null, 'account switch rejects result');
manager.userId = 'alice';
let second = false;
manager.store.getEpochState = async () => { const result = second ? {...durable, epoch: 5} : durable; second = true; return result; };
await assert.rejects(manager.getGroupSecuritySnapshot(base.groupId), /state changed/);

// Execute the production React read callback with deterministic timers. This is
// lifecycle logic evidence, not a browser/camera runtime claim.
const viewText = readFileSync(path.join(web, 'client/src/components/MLSEncryptionInfo.tsx'), 'utf8');
const viewAST = tsCompiler.createSourceFile('View.tsx', viewText, tsCompiler.ScriptTarget.Latest, true, tsCompiler.ScriptKind.TSX);
let callback;
function visit(node) {
  if (tsCompiler.isVariableDeclaration(node) && node.name.getText(viewAST) === 'read') callback = node.initializer.arguments[0].getText(viewAST);
  tsCompiler.forEachChild(node, visit);
}
visit(viewAST); assert.ok(callback);
let waiters = [], deadline;
const ui = {snapshot: null, loading: false, error: false, comparison: null};
const env = {active: true, ownerID: 'alice', groupId: base.groupId, sequence: {current: 0}, reading: {current: false},
  sameCode: (a,b) => a.ownerID === b.ownerID && a.groupID === b.groupID && a.epoch === b.epoch && a.verification?.authenticator === b.verification?.authenticator,
  MLSGroupManager: {shared: () => ({getGroupSecuritySnapshot: () => new Promise(resolve => waiters.push(resolve))})},
  setTimeout: action => { deadline = action; return 1; }, clearTimeout: () => {},
  setLoading: v => {ui.loading = v;}, setError: v => {ui.error = v;}, setSnapshot: v => {ui.snapshot = v;},
  setComparison: f => {ui.comparison = typeof f === 'function' ? f(ui.comparison) : f;}, Error, Promise};
const read = runInNewContext(stripTypeScriptTypes('(' + callback + ')'), env);
const pending = read(); deadline(); await pending;
assert.ok(ui.error && !ui.loading && !env.reading.current, 'deadline ends loading');
waiters.shift()(metadata); await Promise.resolve();
assert.equal(ui.snapshot, null, 'late underlying result cannot revive timeout');
const old = read(), fresh = read();
waiters.shift()(metadata); await old;
assert.ok(ui.loading && ui.snapshot === null, 'obsolete read cannot finish current request');
waiters.shift()(metadata); await fresh;
assert.equal(ui.snapshot, metadata); assert.equal(ui.loading, false);
const closed = read(); env.sequence.current++; ui.snapshot = null;
waiters.shift()(metadata); await closed;
assert.equal(ui.snapshot, null, 'closed or replaced effect rejects late read');
assert.ok(viewText.includes('!reading.current') && viewText.includes('8000'), 'polling cannot continually replace a pending deadline');
const nativeView = readFileSync(path.join(root, 'App/ChatDetailView.swift'), 'utf8');
const groupUI = nativeView.slice(nativeView.indexOf('private struct GroupEncryptionInfo:'), nativeView.indexOf('private struct ConversationEncryptionInfo:'));
assert.ok(groupUI.includes('scanOwner == ownerID') && groupUI.includes('comparison.code == code'));
assert.ok(!groupUI.includes('setPeerVerified') && !viewText.includes('setVerified(true)'));

const QRCode = require('qrcode'), jsQR = require('jsqr');
for (const raw of [qr, native[0].qr]) {
  const grid = QRCode.create(raw, {errorCorrectionLevel: 'M'}).modules;
  const scale = 6, margin = 4, width = (grid.size + margin * 2) * scale;
  const pixels = new Uint8ClampedArray(width * width * 4).fill(255);
  for (let y = 0; y < grid.size; y++) for (let x = 0; x < grid.size; x++) if (grid.get(y, x)) {
    for (let j = 0; j < scale; j++) for (let k = 0; k < scale; k++) {
      const p = (((y + margin) * scale + j) * width + (x + margin) * scale + k) * 4;
      pixels[p] = pixels[p + 1] = pixels[p + 2] = 0;
    }
  }
  const decoded = jsQR(pixels, width, width);
  assert.equal(decoded?.data, raw);
  assert.ok(api.matchesGroupVerification(values[0], decoded.data));
}
console.log('PASS: ' + fixtures.length + ' Swift/Web vectors, independent HMAC oracle, 11 QR acceptance/rejection cases per vector, 2 real offline QR encode/decode roundtrips, production manager/read lifecycle and stale-account guards; synthetic data only');
