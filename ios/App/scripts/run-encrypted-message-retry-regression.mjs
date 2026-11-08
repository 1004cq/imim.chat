// Execute the actual retry method with synthetic messages and HTTP fixtures.
// No real Keychain, app preferences, network, database or message contents.
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(root, 'App/ChatDetailViewModel.swift'), 'utf8');
const view = readFileSync(path.join(root, 'App/ChatDetailView.swift'), 'utf8');
const start = source.indexOf('    func retryEncryptedMessage(');
const end = source.indexOf('    func recoverEncryptionSession', start);
assert.ok(start >= 0 && end > start);
const method = source.slice(start, end).replaceAll('UserDefaults.standard', 'fixtureDefaults');
assert.ok(!method.includes('resetSession') && !method.includes('forceBundleRegistration'));
assert.ok(view.includes('await viewModel.retryEncryptedMessage(message, in: chat'));
const fixture = String.raw`
import Foundation
let domain = "imim-retry-fixture-" + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: domain)!
enum AIConversation { static func matches(_ id: String) -> Bool { id == "bot" } }
@MainActor enum AuthTokenStore {
 static let shared = Token()
 final class Token { var token: String? = "token" }
}
final class Chat { var chatId = "chat", type = "private" }
final class ModelContext {}
final class Message {
 var chatId = "chat", messageId = "target", content = "等待密钥同步", type = "text"
 var mediaURL: String?, voiceURL: String?, voiceDuration: Double?, fileName: String?, fileSize: Int?, mimeType: String?
 var voiceWaveform: [Double] = []
 var stickerURL: String?, stickerEmoji: String?, stickerName: String?, stickerFormat: String?, stickerThumbURL: String?, stickerPackID: String?
 func restoreStickerMetadata(from: String?) {}
}
struct RemoteMessage {
 let id: String, createdAt: String
 var msgType = "encrypted", senderId = "peer", extra: String?
 @MainActor func toLocalMessageResolvingEncryption(currentUserId: String?, persistSession: Bool) async -> Message {
  APIClient.shared.commits.append(persistSession)
  let result = Message(); result.content = APIClient.shared.mode == "unreadable" ? "等待密钥同步" : "synthetic recovered"
  return result
 }
}
@MainActor final class APIClient {
 static let shared = APIClient()
 var mode = "ready", calls = 0, commits: [Bool] = []
 func fetchMessages(chatId: String, before: String?, limit: Int) async throws -> [RemoteMessage] {
  calls += 1
  if mode == "account" { AuthTokenStore.shared.token = "other" }
  if mode == "offline" { throw URLError(.notConnectedToInternet) }
  if mode == "missing" { return [] }
  if mode == "paged", before == nil { return [.init(id: "newer", createdAt: "2")] }
  return [.init(id: "target", createdAt: "1")]
 }
}
@MainActor final class FixtureVM {
 var isLoadingMessages = false, isSending = false, errorMessage: String?, noticeMessage: String?
 var encryptedRetryTicket = UUID(), saves = 0, groupLoads = 0
 func loadMessages(for chat: Chat, modelContext: ModelContext) async { groupLoads += 1 }
 func save(_ context: ModelContext) { saves += 1 }
`;
const checks = String.raw`
}
@main struct RetryRegression {
 @MainActor static func main() async {
  defer { fixtureDefaults.removePersistentDomain(forName: domain) }
  fixtureDefaults.set("owner", forKey: "current_user_id")
  let api = APIClient.shared
  for mode in ["ready", "paged", "unreadable", "missing", "account", "offline"] {
   api.mode = mode; api.calls = 0; api.commits = []; AuthTokenStore.shared.token = "token"
   let vm = FixtureVM(), message = Message(), chat = Chat()
   await vm.retryEncryptedMessage(message, in: chat, modelContext: ModelContext())
   precondition(!vm.isLoadingMessages)
   if mode == "ready" || mode == "paged" {
    precondition(message.content == "synthetic recovered" && vm.saves == 1)
    precondition(api.commits == [false])
    precondition(api.calls == (mode == "paged" ? 2 : 1))
   } else {
    precondition(message.content == "等待密钥同步" && vm.saves == 0)
    if mode == "account" { precondition(vm.noticeMessage == nil && api.commits.isEmpty) }
    if mode == "offline" { precondition(vm.errorMessage != nil) }
   }
  }
  api.mode = "ready"; api.calls = 0; AuthTokenStore.shared.token = "token"
  let vm = FixtureVM(), chat = Chat(), message = Message()
  chat.type = "group"
  await vm.retryEncryptedMessage(message, in: chat, modelContext: ModelContext())
  precondition(vm.groupLoads == 1 && api.calls == 0)
  chat.type = "private"; AuthTokenStore.shared.token = nil
  await vm.retryEncryptedMessage(message, in: chat, modelContext: ModelContext())
  precondition(api.calls == 0)
  print("PASS: production selected-message retry preserves ratchets, paginates, retains failures, routes group to MLS, and blocks account-change/sign-out results")
 }
}
`;
const dir = mkdtempSync(path.join(tmpdir(), 'imim-retry-regression-'));
const file = path.join(dir, 'Regression.swift'), binary = path.join(dir, 'Regression');
writeFileSync(file, fixture + method + checks, {mode: 0o600});
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', file, '-o', binary], {stdio: 'inherit'});
process.exitCode = build.status === 0 ? spawnSync(binary, [], {stdio: 'inherit'}).status ?? 1 : build.status ?? 1;
