// Execute production group submission methods against isolated in-memory models.
// No real API, MLS keys, Keychain, user defaults, SwiftData database or messages.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const vm = readFileSync(path.join(app, 'App/ChatDetailViewModel.swift'), 'utf8');
const view = readFileSync(path.join(app, 'App/ChatDetailView.swift'), 'utf8');
const mls = readFileSync(path.join(app, 'App/MLSGroupManager.swift'), 'utf8');
function declaration(source, marker) {
  const begin = source.indexOf(marker); assert.ok(begin >= 0, marker);
  let end = source.indexOf('{', begin) + 1, depth = 1;
  while (depth && end < source.length) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
  return source.slice(begin, end);
}
const composer = declaration(view, 'private struct ChatTextComposer:');
assert.ok(composer.includes('let onSend: @MainActor (String) async -> Bool'));
assert.ok(composer.includes('isSubmitting = true') && composer.includes('let accepted = await onSend(content)'));
assert.ok(!composer.includes('inputText = ""\n        onSend'));
assert.ok(composer.includes('ProgressView().tint(.white)') && composer.includes('submissionTask?.cancel()'));
assert.ok(view.includes('await viewModel.submitComposerMessage(content'));
const status = declaration(view, 'private var statusStrip:');
assert.ok(status.indexOf('viewModel.errorMessage') < status.indexOf('viewModel.isLoadingMessages'));
const methods = ['func submitComposerMessage(', 'private func sendGroupTextMessage('].map(marker => declaration(vm, marker)).join('\n').replaceAll('UserDefaults.standard', 'fixtureDefaults');
const types = ['struct MLSEncryptedPayload:', 'struct MLSWireEnvelope:', 'enum MLSGroupError:'].map(marker => declaration(mls, marker)).join('\n') + '\n' + declaration(view, 'private enum ChatComposerDraftPolicy').replace('private enum', 'enum');
const harness = String.raw`
import Foundation
let domain = "imim.group-send-fixture." + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: domain)!
final class ModelContext { var saves = 0 }
final class Chat { var vanishMode = false; var type = "group", chatId = "fixture-group", lastMessage = ""; var updatedAt = Date(); var messages: [Message] = [] }
final class Message {
 var messageId: String, status: String, content: String; var createdAt: Date
 init(messageId: String, chatId: String, senderId: String, content: String, type: String, status: String, createdAt: Date, isOutgoing: Bool, chat: Chat?) {
  self.messageId=messageId; self.status=status; self.content=content; self.createdAt=createdAt
 }
}
extension Date { init(milliseconds: Int64) { self.init(timeIntervalSince1970: Double(milliseconds) / 1000) } }
enum APIClientError: LocalizedError { case server(String); var errorDescription: String? { if case .server(let s) = self { return s }; return nil } }
@MainActor final class AuthTokenStore { static let shared = AuthTokenStore(); var token: String? = "fixture-token" }
@MainActor final class MLSGroupManager {
 static let shared = MLSGroupManager(); var mode = "ready", calls = 0, encryptions = 0
 func prepareGroup(groupId: String, userId: String, waitForWelcome: Bool) async throws -> Bool {
  calls += 1
  try await Task.sleep(for: .milliseconds(mode == "slow" ? 80 : 2))
  if mode == "accountChange" { AuthTokenStore.shared.token = "other-token" }
  if mode == "error" { throw URLError(.notConnectedToInternet) }
  return mode != "missing"
 }
 func encrypt(_ content: String, groupId: String, userId: String) async throws -> String {
  encryptions += 1
  return #"{"_mls":true,"epoch":1,"sender":0,"gen":0,"ct":{"ciphertext":"synthetic-only","iv":"synthetic-only"}}"#
 }
}
struct GroupSendResponse { let messageId: String? = "fixture-sent"; let seq = 1; let timestamp: Int64 = 1_000 }
@MainActor final class APIClient {
 static let shared = APIClient(); var mode = "success", calls = 0
 func sendGroupMessage(groupId: String, senderId: String, senderName: String?, encryptedContent: String, replyToId: String?, extra: [String: Any], notificationText: String? = nil) async throws -> GroupSendResponse {
  precondition(extra["mlsEncrypted"] as? Bool == true && encryptedContent.contains("_mls"))
  precondition(!encryptedContent.contains("synthetic draft"))
  precondition(notificationText == "synthetic draft")
  calls += 1
  if mode == "failure" { throw URLError(.timedOut) }
  return GroupSendResponse()
 }
}
@MainActor final class FixtureVM {
 var isSending = false; var errorMessage: String?, noticeMessage: String?, sendingMessageStatus: String?
 var replyingTo: Message?, isShowingAttachmentPanel = false, privateSends = 0
 func save(_ context: ModelContext) { context.saves += 1 }
 func sendMessage(_ content: String, in chat: Chat, modelContext: ModelContext) async { privateSends += 1 }
`;
const main = String.raw`
}
@main struct Regression {
 @MainActor static func main() async {
  defer { fixtureDefaults.removePersistentDomain(forName: domain) }
  fixtureDefaults.set("fixture-owner", forKey: "current_user_id")
  let vm=FixtureVM(), chat=Chat(), context=ModelContext(), mls=MLSGroupManager.shared, api=APIClient.shared
  AuthTokenStore.shared.token=nil
  let signedOut = await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context)
  precondition(!signedOut && chat.messages.isEmpty && !vm.isSending)
  AuthTokenStore.shared.token="fixture-token"
  mls.mode="missing"
  let missing = await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context)
  precondition(!missing && chat.messages.isEmpty && !vm.isSending && vm.sendingMessageStatus == nil && vm.errorMessage != nil && api.calls == 0)
  precondition(ChatComposerDraftPolicy.afterSubmission(current: "draft", submitted: "draft", accepted: missing, cancelled: false) == "draft")
  mls.mode="slow"
  let active=Task { await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context) }
  try? await Task.sleep(for: .milliseconds(5))
  precondition(vm.isSending && vm.sendingMessageStatus == "正在同步群密钥…")
  let duplicate=await vm.submitComposerMessage("duplicate", in: chat, modelContext: context)
  precondition(!duplicate && mls.calls == 2)
  let accepted=await active.value
  precondition(accepted && api.calls == 1 && chat.messages.count == 1 && chat.messages[0].status == "sent" && !vm.isSending && vm.sendingMessageStatus == nil)
  precondition(ChatComposerDraftPolicy.afterSubmission(current: "draft", submitted: "draft", accepted: accepted, cancelled: false).isEmpty)
  precondition(ChatComposerDraftPolicy.afterSubmission(current: "draft + edits", submitted: "draft", accepted: true, cancelled: false) == "draft + edits")
  mls.mode="error"
  let failed=await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context)
  precondition(!failed && !vm.isSending && vm.errorMessage != nil && api.calls == 1)
  mls.mode="ready"; api.mode="failure"
  let failedAfterBubble=await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context)
  precondition(failedAfterBubble && chat.messages.last?.status == "failed" && !vm.isSending)
  api.mode="success"; mls.mode="accountChange"
  let oldAccount=await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context)
  precondition(!oldAccount && api.calls == 2 && !vm.isSending)
  AuthTokenStore.shared.token="fixture-token"; mls.mode="slow"
  let cancelled=Task { await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context) }
  try? await Task.sleep(for: .milliseconds(5)); cancelled.cancel()
  let cancelledResult=await cancelled.value
  precondition(!cancelledResult && api.calls == 2 && !vm.isSending && vm.sendingMessageStatus == nil)
  precondition(ChatComposerDraftPolicy.afterSubmission(current: "draft", submitted: "draft", accepted: true, cancelled: true) == "draft")
  chat.type="private"
  let privateAccepted=await vm.submitComposerMessage("synthetic draft", in: chat, modelContext: context)
  precondition(privateAccepted && vm.privateSends == 1)
  print("PASS: production group submission + draft policy: signed-out/missing keys/network failure retain draft, visible phase, duplicate gate, success, existing failed bubble, account change, cancellation, new edits and private routing")
 }
}
`;
const directory=mkdtempSync(path.join(tmpdir(),'imim-group-send-'));
const source=path.join(directory,'Regression.swift'), binary=path.join(directory,'Regression');
writeFileSync(source,harness+methods+'\n'+main+'\n'+types,{mode:0o600});
const compile=spawnSync('xcrun',['swiftc','-swift-version','5','-parse-as-library',source,'-o',binary],{stdio:'inherit'});
if(compile.status!==0)process.exitCode=compile.status??1;
else process.exitCode=spawnSync(binary,[],{stdio:'inherit'}).status??1;
