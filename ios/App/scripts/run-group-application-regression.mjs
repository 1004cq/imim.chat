import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(app, 'App/APIClient.swift'), 'utf8');
const start = source.indexOf('enum DecryptedGroupText {'); assert.ok(start >= 0);
let end = source.indexOf('{', start) + 1, depth = 1;
while (depth && end < source.length) {if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++;}
assert.ok(source.includes('displayContent = DecryptedGroupText.content(plaintext)'));
const code = 'import Foundation\n' + source.slice(start, end) + String.raw`
precondition(DecryptedGroupText.content("plain native text") == "plain native text")
precondition(DecryptedGroupText.content(#"{"content":"网页消息 👋","msgType":"text","extra":{}}"#) == "网页消息 👋")
precondition(DecryptedGroupText.content(#"{"content":"","msgType":"text"}"#).isEmpty)
for value in [#"{"content":"user JSON"}"#, #"{"content":42,"msgType":"text"}"#, #"{"content":"file","msgType":"image"}"#, "{broken", "[]"] {
 precondition(DecryptedGroupText.content(value) == value)
}
print("PASS: production decrypted group text parser: structured web text, legacy native text, Unicode, empty text, non-application JSON and malformed payloads; no keys or network")
`;
const root = mkdtempSync(path.join(tmpdir(), 'imim-group-application-'));
writeFileSync(path.join(root, 'Regression.swift'), code, {mode: 0o600});
const compile = spawnSync('xcrun', ['swiftc', '-swift-version', '5', path.join(root, 'Regression.swift'), '-o', path.join(root, 'Regression')], {stdio: 'inherit'});
process.exitCode = compile.status === 0 ? spawnSync(path.join(root, 'Regression'), [], {stdio: 'inherit'}).status ?? 1 : compile.status ?? 1;
