// Source integration guards, not a substitute for device tap/VoiceOver testing.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const app = new URL('../App/', import.meta.url);
const source = readFileSync(new URL('ChatDetailView.swift', app), 'utf8');
const from = source.indexOf('    private var conversationEncryptionBanner:');
const banner = source.slice(from, source.indexOf('    private var messagesView:', from));
assert.ok(banner.includes('Button {'));
assert.ok(banner.includes('isShowingEncryptionInfo = true'));
assert.ok(banner.includes('.frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 240 : 200, minHeight: 52)'));
assert.ok(banner.includes('.contentShape(Capsule())') && banner.includes('ConversationGlassSurface()'));
assert.ok(!banner.includes('DoveTheme.green'), 'Encryption entry must not be an isolated green rectangle');
assert.ok(banner.includes('.accessibilityIdentifier("chat.encryption.info")'));
assert.ok(banner.includes('chat.type == "group" ? "MLS" : "Signal Protocol"'));
assert.ok(source.includes('.sheet(isPresented: $isShowingEncryptionInfo)'));
assert.ok(source.includes('ConversationEncryptionInfo(isGroup: chat.type == "group", peerID: presencePeerID, peerName: chat.name)'));
const info = source.slice(source.indexOf('private struct ConversationEncryptionInfo:'), source.indexOf('private struct AIConsentPanel:'));
assert.ok(info.includes('Button("关闭") { dismiss() }'));
assert.ok(!/APIClient|resetSession|synchronizeCurrentUser|bootstrapForCurrentUser|encryptText|decryptText|MLSGroupManager/.test(info), 'Details must not establish/reset sessions, consume prekeys or advance ratchets');
assert.ok(info.includes('expectedBinding: candidate'));
assert.ok(info.includes('value.binding == expectedBinding'));
assert.ok(info.includes('currentInfo?.matchesQR(payload)'));
assert.ok(info.includes('.task(id: refreshIdentity)'));
assert.ok(info.includes('.presentationDetents([.large])'));
assert.ok(info.includes('.task(id: loadGate.ticket)'));
assert.ok(info.includes('expireRead(ticket)'));
assert.ok(info.includes('.accessibilityIdentifier("chat.security.refresh")'));
assert.ok(!info.includes('guard scenePhase == .active'), 'Initial sheet loading must not silently stall in a transient inactive scene');
const catalog = JSON.parse(readFileSync(fileURLToPath(new URL('Localizable.xcstrings', app)), 'utf8'));
for (const key of ['加密说明', '打开加密说明', '加密协议',
  '群聊使用 MLS。消息解密依赖参与设备持有的群密钥。',
  '私聊使用 Signal Protocol。消息解密依赖参与设备持有的会话密钥。',
  '此处为加密说明，不代表已完成联系人身份验证。请通过可信渠道核对对方身份。此页不会显示、导出或重置密钥。']) {
  for (const lang of ['en', 'zh-Hans']) assert.ok(catalog.strings[key]?.localizations?.[lang]?.stringUnit?.value);
}
console.log('PASS: encryption banner, accessible hit target, bilingual details, private/group labels, bound verification confirmation and no ratchet/session mutations');
