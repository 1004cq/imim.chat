// Source integration/layout intent checks. Not pixel, touch, VoiceOver or FPS proof.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(root, 'App/ChatDetailView.swift'), 'utf8');
function section(a, b) {
  const start = source.indexOf(a), end = source.indexOf(b, start + a.length);
  assert.ok(start >= 0 && end > start, a); return source.slice(start, end);
}
const base = section('    private var chatBaseContent:', '    private var voiceAwareContent:');
const header = section('    private var conversationHeader:', '    private var conversationEncryptionBanner:');
const security = section('    private var conversationEncryptionBanner:', '    private var messagesView:');
const helpers = section('private struct ConversationFloatingTopBar<', '// Value-only admission gate:');
assert.ok(!base.includes('if isAIConversation { header }'));
assert.ok(base.includes('ConversationFloatingTopBar(isEnabled: true)'));
assert.ok(!base.includes('\n                encryptionBanner\n'), 'No second encryption strip');
assert.ok(header.includes('ConversationGlassGroup {'));
assert.ok(header.includes('conversationEncryptionBanner'));
assert.ok(header.includes('Button { dismiss() }'));
assert.ok(source.includes('startCall(.audio)') && source.includes('startCall(.video)'), 'Calls retain their existing other entrances');
assert.ok(header.includes('isShowingChatSettings = true'));
assert.ok(header.includes('Button {\n                    dismissInputSurfaces()\n                    isShowingChatSettings = true'), 'Avatar single tap opens existing details route');
assert.ok(!header.includes('.contextMenu {') && !header.includes('                Menu {'), 'Avatar only opens details, without a menu');
assert.ok(header.includes('.accessibilityIdentifier("chat.header.details")'));
assert.ok(header.includes('DoveAvatar(name: chat.name, url: chat.avatar, userId: chat.avatarCacheIdentity'));
const back = header.slice(header.indexOf('Button { dismiss() }'), header.indexOf('conversationEncryptionBanner'));
assert.ok(back.includes('.frame(width: 52, height: 52)') && back.includes('.fixedSize()'), 'Back control cannot compress');
assert.ok(!back.includes('Text("返回").font'), 'Back label must not wrap into a vertical word');
assert.ok(back.includes('.accessibilityLabel(Text("返回"))'), 'Keep the spoken back action');
assert.equal((header.match(/Spacer\(minLength: 12\)/g) ?? []).length, 2, 'Symmetric space centers title');
assert.ok(!header.includes('.layoutPriority(1)'), 'Title must not squeeze either side control');
assert.ok(security.includes('.frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 240 : 200, minHeight: 52)'), 'Bound title width while accommodating accessibility type');
assert.ok(!header.includes('.background(Color(uiColor: .systemBackground)') && !header.includes('.overlay(alignment: .bottom)'), 'No opaque toolbar strip/divider');
assert.ok(security.includes('Text(chat.name).font(.headline).lineLimit(1)'));
assert.ok(security.includes('Text(verbatim: peerStatusText)'));
assert.ok(security.includes('friendPresence.snapshot(for: presencePeerID)') && !security.includes('socket.isConnected'));
assert.ok(security.includes('isInputFocused = false') && security.includes('isShowingEncryptionInfo = true'));
assert.ok(security.includes('.accessibilityIdentifier("chat.encryption.info")') && security.includes('.accessibilityHint(Text(isAIConversation ? "聊天详情" : "打开加密说明"))'));
assert.ok(security.includes('chat.type == "group" ? "MLS" : "Signal Protocol"'));
assert.ok(helpers.includes('content.safeAreaBar(edge: .top, spacing: 0)') && helpers.includes('content.safeAreaInset(edge: .top, spacing: 0)'));
assert.ok(helpers.includes('GlassEffectContainer(spacing: 6)') && helpers.includes('#available(iOS 26, *)'));
assert.ok(helpers.includes('if reduceTransparency') && helpers.includes('.background(.ultraThinMaterial, in: Capsule())'));
assert.ok(helpers.includes('.interactive(!reduceMotion)'));
assert.ok(!/URLSession|APIClient|E2EEManager|MLSGroupManager|UserDefaults|AppStorage|UIApplication|\.id\(/.test(header + security + helpers));
assert.ok(base.includes('.safeAreaInset(edge: .bottom, spacing: 0)') && !helpers.includes('.ignoresSafeArea(.keyboard'));
assert.ok(source.includes('ForEach(Array(messageItems.enumerated()), id: \\.element.messageId)'));
const catalog = JSON.parse(readFileSync(path.join(root, 'App/Localizable.xcstrings'), 'utf8'));
for (const key of ['聊天详情', '返回', '语音通话', '视频通话', '打开加密说明']) {
  for (const language of ['en', 'zh-Hans']) assert.ok(catalog.strings[key]?.localizations?.[language]?.stringUnit?.value, key + '/' + language);
}
console.log('PASS: floating three-control header, native glass/material/opaque accessibility fallbacks, safe-area reservation, existing security/call/menu/identity wiring and bilingual labels; source checks only');
