// Presentation-only boundary checks. Complements, not replaces, a device build
// and visual/VoiceOver checks; does not call a model, network, or microphone.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../App');
const view = readFileSync(path.join(app, 'ChatDetailView.swift'), 'utf8');
const catalog = JSON.parse(readFileSync(path.join(app, 'Localizable.xcstrings'), 'utf8'));
const section = (start, end) => {
  const from = view.indexOf(start), to = view.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, start);
  return view.slice(from, to);
};
const base = section('    private var chatBaseContent:', '    private var voiceAwareContent:');
const messages = section('    private var messagesView:', '    private func performInitialScrollIfNeeded(');
const row = section('private struct MessageBubble:', 'private struct HeaderIconButton:');
const composer = section('private struct AIMessageComposer:', 'private struct ComposerInsertion:');
const peerComposer = section('private struct ChatTextComposer:', 'private struct AttachmentAction:');
const layout = section('private struct ConversationComposerLayout<', 'private struct ChatTextComposer:');
const title = section('    private var conversationEncryptionBanner:', '    private var messagesView:');
assert.ok(base.includes('ConversationBackground(style: chatBackgroundStyle)'));
assert.ok(base.includes('ConversationFloatingTopBar(isEnabled: true)'));
assert.ok(!/AIAssistantHeader|AIAssistantWelcome|AIAssistantMessageRow/.test(view), 'One active header and bubble implementation');
assert.ok(messages.includes('MessageBubble(') && messages.includes('isAIConversation: isAIConversation'));
assert.ok(messages.includes('if shouldShowTimeGroup(') && !messages.includes('isAIConversation ? 760'));
assert.ok(title.includes('if isAIConversation { isShowingChatSettings = true }'));
assert.ok(title.includes('else { isShowingEncryptionInfo = true }'));
assert.ok(title.includes('isAIConversation ? "sparkles" : "lock.shield"'));
assert.ok(title.includes('isAIConversation ? AppLocalization.string("AI 对话由 DeepSeek 处理")'));
assert.ok(row.includes('Text(verbatim: message.content)'));
assert.ok(row.includes('Text(AIAssistantTypography.formattedReply(message.content))'));
assert.ok(row.includes('else if isForwardingRestricted') && row.includes('baseTextBubble.textSelection(.enabled)'));
assert.ok(row.includes('if !isForwardingRestricted') && row.includes('UIPasteboard.general.string = message.content'));
assert.ok(row.includes('if !isAIConversation {\n                        Button {'), 'AI context menu cannot call peer-only reply/recall/mention paths');
assert.ok(row.includes('isAIConversation && message.content.isEmpty && message.status == "sending"'));
assert.ok(row.includes('!isAIConversation && message.content.contains("等待密钥同步")'));
assert.ok(row.includes('ai.reply.thinking'));
assert.ok(row.includes('message.status == "failed"'));
assert.ok(!/URLSession|Signal Protocol/.test(row));
assert.ok(composer.includes('ConversationComposerLayout {') && peerComposer.includes('ConversationComposerLayout {'));
assert.ok(layout.includes('HStack(alignment: .center, spacing: 9)') && layout.includes('.frame(height: 40)'));
assert.ok(layout.includes('.secondarySystemBackground') && layout.includes('cornerRadius: 20'));
assert.ok(composer.includes('.accessibilityIdentifier("ai.message.send")'));
assert.ok(composer.includes('.onSubmit(submit)'));
assert.ok(composer.includes('.focused($isInputFocused)'));
assert.ok(composer.includes('guard !text.isEmpty, !isSending, !audioBusy else { return }'));
assert.ok(composer.includes('AIInputTouchSurface(isEnabled:'));
assert.ok(composer.includes('if isSending { onStop() } else { submit() }'));
assert.ok(composer.includes('.disabled(!isSending && (!canSend || audioBusy))'));
assert.ok(composer.includes('"paperplane.fill"') && composer.includes('"mic.fill"') && composer.includes('"face.smiling"'));
assert.ok(composer.includes('onTap: toggleConversation') && composer.includes('onHoldEnded: onHoldEnded'));
assert.ok(composer.includes('EmojiPickerPanel { emoji in') && composer.includes('inputText += emoji'));
assert.ok(composer.includes('$voice.autoReadReplies') && composer.includes('Button(action: onStartConversation)'));
assert.ok(view.includes('.safeAreaInset(edge: .bottom, spacing: 0)'));
for (const key of ['AI 对话由 DeepSeek 处理', 'AI 正在思考…', '连续语音对话', '停止生成', '更多 AI 选项', '聊天详情', '返回']) {
  for (const language of ['en', 'zh-Hans']) {
    assert.equal(catalog.strings[key]?.localizations?.[language]?.stringUnit?.state, 'translated', `${key}/${language}`);
  }
}
console.log('PASS: shared AI/peer header, bubble and composer geometry; AI provider/consent boundaries, streaming/failure/copy/voice actions and bilingual labels (source integration only)');
const typography = section('private enum AIAssistantTypography', 'private struct AIMessageComposer:');
const directory = mkdtempSync(path.join(tmpdir(), 'imim-ai-typography-'));
const swift = path.join(directory, 'Regression.swift');
writeFileSync(swift, 'import Foundation\n' + typography + String.raw`
@main struct TypographyRegression {
    static func main() {
        let plain = "你好，世界 👋"
        precondition(String(AIAssistantTypography.formattedReply(plain).characters) == plain)
        let bold = AIAssistantTypography.formattedReply("我是 **imim AI**。")
        precondition(String(bold.characters) == "我是 imim AI。")
        precondition(bold.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let code = AIAssistantTypography.formattedReply("Use \u{0060}print()\u{0060}")
        precondition(String(code.characters) == "Use print()")
        precondition(code.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        let lines = "first\n\n  second"
        precondition(String(AIAssistantTypography.formattedReply(lines).characters) == lines)
        precondition(!AIAssistantTypography.formattedReply("**partial").characters.isEmpty)
        let link = AIAssistantTypography.formattedReply("[label](https://example.invalid)")
        precondition(link.runs.allSatisfy { $0.link == nil })
        print("PASS: 8 production typography assertions; inline emphasis/code, Unicode, paragraphs, partial reply and no added URL actions")
    }
}
`);
const binary = path.join(directory, 'Regression');
const build = spawnSync('xcrun', ['swiftc', '-parse-as-library', swift, '-o', binary], {stdio:'inherit'});
if (build.status !== 0) process.exitCode = build.status ?? 1;
else process.exitCode = spawnSync(binary, [], {stdio:'inherit'}).status ?? 1;
