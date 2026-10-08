import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../App');
const catalog = JSON.parse(fs.readFileSync(path.join(app, 'Localizable.xcstrings'), 'utf8'));
assert.equal(catalog.sourceLanguage, 'zh-Hans');
for (const [key, item] of Object.entries(catalog.strings)) {
  for (const language of ['en', 'zh-Hans']) {
    const unit = item.localizations?.[language]?.stringUnit;
    assert.ok(unit?.value, `${key}: missing ${language}`);
    assert.equal(unit.state, 'translated', `${key}: untranslated ${language}`);
  }
  // Interpolated values must remain available in both languages. Never consume
  // nicknames/message text as translation keys or substitute a bare user ID.
  const placeholders = s => (s.match(/%(?:\d+\$)?(?:lld|ld|d|@|f)/g) || []).map(x => x.replace(/\d+\$/, '')).sort();
  assert.deepEqual(placeholders(item.localizations.en.stringUnit.value), placeholders(key), key);
}
const root = fs.readFileSync(path.join(app, 'AppEntry.swift'), 'utf8');
assert.ok(root.includes('@AppStorage(AppLanguage.preferenceKey)'));
assert.ok(root.includes('.environment(\\.locale,'));
assert.ok(!root.includes('.id(languagePreference)'), 'Language changes must not reset chat state');
const chat = fs.readFileSync(path.join(app, 'ChatDetailView.swift'), 'utf8');
assert.ok(chat.includes('Text(message.content)'), 'User messages must stay verbatim');
assert.ok(chat.includes('Text(chat.name)'), 'Peer names must stay verbatim');
console.log(`PASS: ${Object.keys(catalog.strings).length} bilingual entries, matching placeholders, persistent preference, unchanged user content`);
