// Execute production AI-only view-model methods with isolated defaults, synthetic
// models/context and a fake streaming transport. No UI/network/provider access.
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const vm = readFileSync(path.join(app, 'App/ChatDetailViewModel.swift'), 'utf8');
const api = readFileSync(path.join(app, 'App/APIClient.swift'), 'utf8');
function declaration(source, marker) {
  const begin = source.indexOf(marker);
  assert.ok(begin >= 0, marker);
  let end = source.indexOf('{', begin) + 1, depth = 1;
  while (depth && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  return source.slice(begin, end);
}
let send = vm.slice(vm.indexOf('    func sendMessage('), vm.indexOf('        if chat.type == "group" {', vm.indexOf('    func sendMessage('))) + '\n    }';
const methods = [send, declaration(vm,'func sortedMessages('), declaration(vm,'private var aiConsentKey:'),
  declaration(vm,'private var hasAIConsent:'), declaration(vm,'func acceptAIConsent('),
  declaration(vm,'func cancelAIConsent('), declaration(vm,'func cancelAIRequest('), declaration(vm,'private func sendAIText(')]
  .join('\n').replaceAll('UserDefaults.standard', 'fixtureDefaults');
const types = [declaration(api,'enum AIConversation'), declaration(api,'struct AIChatTurn:'), declaration(vm,'struct AICompletedReply:')].join('\n');
const harness = String.raw`
import Foundation
import Combine
let fixtureDomain = "imim.ai-send-fixture." + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: fixtureDomain)!
@MainActor enum AIFlowTrace {
    enum Event { case sendTapped, consentAccepted, requestStarted, firstDelta, requestCompleted, requestCancelled, requestFailed }
    static func record(_ event: Event) {}
}
@MainActor final class AuthTokenStore {
    static let shared = AuthTokenStore()
    var token: String? = "synthetic-fixture-token"
}
final class ModelContext { var saves = 0 }
final class Chat {
    var chatId = "bot"
    var messages: [Message] = []
    var lastMessage = ""
    var updatedAt = Date()
}
final class Message {
    let messageId: String, chatId: String, senderId: String, type: String
    var content: String, status: String
    let createdAt: Date, isOutgoing: Bool
    init(messageId: String, chatId: String, senderId: String, content: String, type: String, status: String, createdAt: Date, isOutgoing: Bool, chat: Chat?) {
        self.messageId=messageId;self.chatId=chatId;self.senderId=senderId;self.content=content
        self.type=type;self.status=status;self.createdAt=createdAt;self.isOutgoing=isOutgoing
    }
}
@MainActor final class APIClient {
    static let shared = APIClient()
    var calls = 0, mode = "success"
    var latestTurns: [AIChatTurn] = []
    func streamAIReply(turns: [AIChatTurn], onText: @escaping @MainActor (String) -> Void) async throws -> String {
        calls += 1; latestTurns = turns
        try await Task.sleep(for: .milliseconds(mode == "cancel" ? 200 : 5))
        if mode == "failure" { throw URLError(.notConnectedToInternet) }
        onText("synthetic answer")
        return "synthetic answer"
    }
}
@MainActor final class FixtureVM: ObservableObject {
    @Published var isShowingAIConsent = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var completedAIReply: AICompletedReply?
    var replyingTo: Message?
    var pendingAIText: String?, pendingAIOwner: String?
    var aiTask: Task<Void, Never>?
    func save(_ context: ModelContext) { context.saves += 1 }
`;
const main = String.raw`
}
@main struct Regression {
    @MainActor static func main() async {
        defer { fixtureDefaults.removePersistentDomain(forName: fixtureDomain) }
        fixtureDefaults.set("fixture-owner", forKey:"current_user_id")
        let vm=FixtureVM(), chat=Chat(), context=ModelContext(), api=APIClient.shared
        await vm.sendMessage("  first question  ", in:chat, modelContext:context)
        precondition(vm.isShowingAIConsent && api.calls == 0 && chat.messages.isEmpty)
        precondition(vm.acceptAIConsent() == "first question")
        precondition(!vm.isShowingAIConsent && vm.pendingAIText == nil)
        await vm.sendMessage("first question", in:chat, modelContext:context)
        precondition(api.calls == 1 && chat.messages.count == 2 && !vm.isSending)
        precondition(chat.messages.first?.status == "sent" && chat.messages.last?.status == "received")
        precondition(vm.completedAIReply?.text == "synthetic answer" && context.saves == 1)
        await vm.sendMessage("follow-up", in:chat, modelContext:context)
        precondition(api.latestTurns.map(\.role) == ["user", "assistant", "user"])
        precondition(!vm.isSending && vm.errorMessage == nil)
        api.mode="failure"
        await vm.sendMessage("synthetic failure", in:chat, modelContext:context)
        precondition(!vm.isSending && vm.errorMessage != nil && vm.completedAIReply == nil)
        precondition(chat.messages.suffix(2).allSatisfy { $0.status == "failed" })
        api.mode="cancel"
        let sending=Task { await vm.sendMessage("synthetic cancellation", in:chat, modelContext:context) }
        while !vm.isSending { await Task.yield() }
        vm.cancelAIRequest()
        await sending.value
        precondition(!vm.isSending && vm.completedAIReply == nil)
        fixtureDefaults.set("another-owner", forKey:"current_user_id")
        await vm.sendMessage("draft to restore", in:chat, modelContext:context)
        precondition(vm.cancelAIConsent() == "draft to restore" && !vm.isShowingAIConsent)
        await vm.sendMessage("old account draft", in:chat, modelContext:context)
        fixtureDefaults.set("third-owner", forKey:"current_user_id")
        precondition(vm.acceptAIConsent() == nil && vm.cancelAIConsent().isEmpty)
        precondition(vm.sortedMessages(for:chat).isEmpty)
        print("PASS: 14 production AI-send flow assertions; first consent, accept/send, streaming completion, follow-up, transport failure, cancellation, draft recovery and account separation")
    }
}
`;
const directory=mkdtempSync(path.join(tmpdir(),'imim-ai-send-flow-'));
const swift=path.join(directory,'Regression.swift');
writeFileSync(swift,harness+methods+'\n'+main+'\n'+types);
const binary=path.join(directory,'Regression');
const build=spawnSync('xcrun',['swiftc','-swift-version','5','-parse-as-library',swift,'-o',binary],{stdio:'inherit'});
if(build.status!==0)process.exitCode=build.status??1;
else process.exitCode=spawnSync(binary,[],{stdio:'inherit'}).status??1;
