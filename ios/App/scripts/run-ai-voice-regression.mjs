// Production pure-state/text execution + source boundary guards. No microphone,
// model call, network, private messages or permissions are used by this fixture.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(app, 'App/VoiceRecorderManager.swift'), 'utf8');
const view = readFileSync(path.join(app, 'App/ChatDetailView.swift'), 'utf8');
const vm = readFileSync(path.join(app, 'App/ChatDetailViewModel.swift'), 'utf8');
const controller = source.slice(source.indexOf('final class AIVoiceController'));
assert.ok(controller.includes('request.requiresOnDeviceRecognition = true'));
assert.ok(controller.includes('recognizer.supportsOnDeviceRecognition'));
assert.ok(controller.includes('AuthTokenStore.shared.token == sessionToken'));
assert.ok(controller.includes('UIApplication.shared.applicationState == .active'));
assert.ok(controller.includes('!callObserver.calls.contains(where: { !$0.hasEnded })'));
assert.ok(controller.includes('synthesizer.usesApplicationAudioSession = false'));
assert.ok(controller.includes('permissionTask?.cancel()') && controller.includes('recognitionTask?.cancel()'));
assert.ok(controller.includes('if generation == ticket { stopAll() }'));
assert.ok(controller.includes('didEnterBackgroundNotification') && controller.includes('cqimCallInviteDidReceive'));
assert.ok(controller.includes('oldDeviceUnavailable.rawValue'));
assert.ok(!/URLSession|AVAudioRecorder|write\(to:|print\(/.test(controller));
assert.ok(view.includes('if isAIConversation { aiVoice.deactivate(); viewModel.cancelAIRequest() }'));
assert.ok(view.includes('reply.ownerID == authSession.currentUser?.id'));
assert.ok(view.includes('utterance.ownerID == authSession.currentUser?.id'));
assert.ok(view.includes('phase == .inactive && !aiVoice.isPreparing'));
assert.ok(view.includes('AIMessageComposer(voice: aiVoice'));
assert.ok(view.includes('UILongPressGestureRecognizer(target: context.coordinator'));
assert.ok(view.includes('tap.require(toFail: hold)'));
assert.ok(!view.includes('@GestureState private var holdGestureActive'));
assert.ok(view.includes('case .cancelled, .failed: finish(cancelled: true)'));
assert.ok(view.includes('aiVoice.endPushToTalk(cancelled: cancelled)'));
assert.ok(view.includes('if kind == .holdVoice { aiVoice.preparePushToTalk() }'));
assert.ok(view.includes('.sheet(item: $aiConsent'));
assert.ok(!view.includes('.alert("imim AI · DeepSeek"'));
const entry = view.slice(view.indexOf('private var entry: some View {'), view.indexOf('private func submit()', view.indexOf('private var entry: some View {')));
assert.ok(/^private var entry: some View \{\s*TextField/.test(entry));
assert.ok(entry.indexOf('.focused($isInputFocused)') < entry.indexOf('.overlay {'));
assert.ok(controller.includes('if final && !isHoldingToTalk { finishListening() }'));
assert.ok(controller.includes('if conversationEnabled && !next.isEmpty'));
assert.ok(controller.includes('else { self.isPreparing = false; self.hintMessage ='));
const release = controller.slice(controller.indexOf('func endPushToTalk'), controller.indexOf('private func startListening'));
assert.ok(release.includes('stopAudioInput()') && release.includes('recognitionRequest?.endAudio()'));
assert.ok(release.includes('if cancelled { stopAll();'));
assert.ok(release.includes('Task.sleep(for: .milliseconds(1500))'));
const completion = vm.indexOf('completedAIReply = AICompletedReply');
assert.ok(completion > vm.indexOf('reply.content = result; reply.status = "received"'));
assert.ok(completion < vm.indexOf('} catch {', completion));
console.log('PASS: source guards for on-device-only recognition, hold/release/cancel, permission preparation without recording, bounded finalization, account/foreground/call ownership and cleanup');

const begin = source.indexOf('enum AIVoiceText');
const end = source.indexOf('@MainActor\nfinal class AIVoiceController', begin);
const production = source.slice(begin, end);
const fixture = String.raw`
import Foundation
@main struct Regression {
    static func main() {
        precondition(AIVoiceText.transcript("  你好 hello\n") == "你好 hello")
        precondition(AIVoiceText.transcript("  \n").isEmpty)
        precondition(AIVoiceText.transcript(String(repeating: "中", count: 7000)).count == 6000)
        precondition(AIVoiceText.spokenReply("## Hello **world** [Apple](https://example.invalid)") == "Hello world Apple")
        precondition(!AIVoiceText.spokenReply("before\n\u{0060}\u{0060}\u{0060}swift\nlet secret = 1\n\u{0060}\u{0060}\u{0060}\nafter").contains("secret"))
        precondition(AIVoiceText.spokenReply(String(repeating: "a", count: 15000)).count == 12000)
        var capture = AIVoiceCapture()
        precondition(capture.consume() == nil)
        let first = capture.begin()
        precondition(capture.update("第一句话", id: first) == "第一句话")
        precondition(capture.consume() == "第一句话")
        precondition(capture.consume() == nil) // final + silence cannot send twice
        precondition(capture.update("late result", id: first) == nil)
        let second = capture.begin()
        precondition(first != second)
        precondition(capture.update("old account text", id: first) == nil)
        precondition(capture.update("new turn", id: second) == "new turn")
        capture.cancel()
        precondition(capture.id == nil)
        precondition(capture.consume() == nil)
        precondition(capture.update("after background/call/exit", id: second) == nil)
        _ = capture.begin()
        precondition(capture.consume() == "")
        var hold = AIHoldInteraction()
        precondition(hold.finish(cancelled: false) == nil)
        precondition(hold.begin())
        precondition(!hold.begin())
        hold.move(vertical: -80)
        precondition(hold.finish(cancelled: false) == true)
        precondition(hold.finish(cancelled: false) == nil)
        _ = hold.begin()
        hold.move(vertical: 20)
        precondition(hold.finish(cancelled: false) == false)
        _ = hold.begin()
        precondition(hold.finish(cancelled: true) == true)
        precondition(!hold.isActive && !hold.isCancelling)
        print("PASS: 26 production text/capture/hold assertions; stale callback rejection, one-shot release and cancellation")
    }
}
`;
const directory = mkdtempSync(path.join(tmpdir(), 'imim-ai-voice-'));
const swift = path.join(directory, 'Regression.swift');
writeFileSync(swift, fixture + '\n' + production);
const binary = path.join(directory, 'Regression');
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', swift, '-o', binary], {stdio:'inherit'});
if (build.status !== 0) process.exitCode = build.status ?? 1;
else process.exitCode = spawnSync(binary, [], {stdio:'inherit'}).status ?? 1;
