// Compile the real native E2EE manager using its memory-only regression store.
// Pass a checked-out Web CryptoUtils.ts to compare the actual deployed encoding.
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {stripTypeScriptTypes} from 'node:module';
import {webcrypto} from 'node:crypto';
import assert from 'node:assert/strict';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const webPath = process.argv[2];
assert.ok(webPath, 'Usage: node run-e2ee-security-regression.mjs /path/to/client/src/lib/e2ee/CryptoUtils.ts');
const web = readFileSync(webPath, 'utf8');
function declaration(name) {
  const start = web.search(new RegExp(`export (?:async )?function ${name}\\(`));
  assert.ok(start >= 0, name);
  let end = web.indexOf('{', start) + 1, depth = 1;
  while (depth && end < web.length) { if (web[end] === '{') depth++; if (web[end] === '}') depth--; end++; }
  return web.slice(start, end).replace(/^export /, '');
}
const functions = ['bufferToBase64', 'base64ToBuffer', 'bufferToHex', 'concatBuffers', 'sha256', 'generateSafetyNumber', 'fingerprint'];
const js = stripTypeScriptTypes(functions.map(declaration).join('\n'));
const actualWeb = new Function('crypto', js + '\nreturn {generateSafetyNumber,fingerprint};')(webcrypto);
const vectors = [];
for (let i = 0; i < 3; i++) {
  const local = Buffer.from(Array.from({length: 91}, (_, n) => (n * (i + 1) + i) % 256)).toString('base64');
  const remote = Buffer.from(Array.from({length: 91}, (_, n) => (255 - n * (i + 2) + 256) % 256)).toString('base64');
  vectors.push({local, remote, number: await actualWeb.generateSafetyNumber(local, remote), fingerprint: await actualWeb.fingerprint(local)});
}
const directory = mkdtempSync(path.join(tmpdir(), 'imim-security-regression-'));
const generated = path.join(directory, 'WebVectors.swift');
writeFileSync(generated, `enum WebSafetyVectors {\nstruct Vector { let local: String; let remote: String; let number: String; let fingerprint: String }\nstatic let values: [Vector] = [\n` +
  vectors.map(v => `.init(local: ${JSON.stringify(v.local)}, remote: ${JSON.stringify(v.remote)}, number: ${JSON.stringify(v.number)}, fingerprint: ${JSON.stringify(v.fingerprint)})`).join(',\n') + '\n]\n}\n');
const binary = path.join(directory, 'E2EESecurityRegression');
const build = spawnSync('xcrun', ['swiftc', '-D', 'E2EE_REGRESSION_TESTS', '-parse-as-library',
  path.join(root, 'App/E2EEEnvelope.swift'), path.join(root, 'App/EncryptedMediaStore.swift'),
  path.join(root, 'scripts/E2EESecurityRegression.swift'), generated, '-o', binary],
  {stdio: 'inherit', env: {...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer'}});
if (build.status !== 0) process.exit(build.status ?? 1);
const run = spawnSync(binary, [], {stdio: 'inherit'});
if (run.status !== 0) process.exit(run.status ?? 1);
