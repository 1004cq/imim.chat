import Foundation
import SwiftData

@main @MainActor
struct CallHistoryRegression {
    static var checks = 0
    static func check(_ value: Bool, _ note: String) { precondition(value, note); checks += 1 }
    static func main() throws {
        var owner: String? = "fixture-owner"
        var clock = Date(timeIntervalSince1970: 1000)
        let schema = Schema([User.self, Chat.self, Message.self])
        let config = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: CommandLine.arguments[1]))
        var container: ModelContainer? = try ModelContainer(for: schema, configurations: config)
        var context: ModelContext? = ModelContext(container!)
        let store = CallHistoryStore(owner: { owner }, now: { clock })
        store.configure(context!)
        let chat = Chat(chatId: "fixture-chat", name: "Peer", updatedAt: .distantPast, memberIds: ["fixture-owner", "peer"])
        context!.insert(chat)
        try context!.save()
        func begin(_ id: String, incoming: Bool = false, video: Bool = false) -> CallHistoryStore.Token? {
            store.begin(callID: id, peerID: "peer", mediaKind: video ? "video" : "audio", isIncoming: incoming, chatID: chat.chatId)
        }
        func rows() throws -> [Message] { try context!.fetch(FetchDescriptor<Message>()) }
        func entry(_ id: String) throws -> CallHistoryEntry {
            let entries = try rows().map { try JSONDecoder().decode(CallHistoryEntry.self, from: Data($0.content.utf8)) }
            return entries.first(where: { $0.callID == id })!
        }
        let outgoing = begin("connected")
        check(outgoing == begin("connected"), "duplicate delivery has stable owner/peer/call identity")
        check(try rows().isEmpty, "starting a call does not persist an unfinished result")
        clock = clock.addingTimeInterval(12)
        store.connected(outgoing)
        clock = clock.addingTimeInterval(70)
        store.connected(outgoing)
        store.finish(outgoing, reason: .endedLocally)
        let completed = try entry("connected")
        check(completed.outcome == .completed && completed.durationSeconds == 70, "duration excludes ringing and repeated connected events")
        check(completed.formattedDuration == "01:10" && completed.titleKey == "语音通话", "duration and outgoing audio presentation")
        store.finish(outgoing, reason: .failed)
        let duplicate = begin("connected")
        store.finish(duplicate, reason: .declined)
        check(try rows().count == 1 && entry("connected").outcome == .completed, "multiple terminal callbacks and duplicate invitations cannot overwrite a final result")
        check(chat.messages.count == 1 && chat.messages[0].type == "call", "record appears in the existing chat relationship")
        check(chat.messages[0].status == "local" && chat.messages[0].senderId == "fixture-owner", "no false delivery receipt and correct outgoing identity")
        let missed = begin("missed", incoming: true, video: true)
        store.finish(missed, reason: .endedRemotely)
        check(try entry("missed").outcome == .missed && entry("missed").titleKey == "未接视频来电", "unanswered incoming video is missed")
        check(try entry("missed").durationSeconds == 0 && chat.messages.contains { !$0.isOutgoing }, "missed duration/direction")
        let cancelled = begin("cancelled")
        store.finish(cancelled, reason: .endedLocally)
        check(try entry("cancelled").outcome == .cancelled, "outgoing local hangup before connection is cancelled")
        let declined = begin("declined", incoming: true)
        store.finish(declined, reason: .declined)
        check(try entry("declined").titleKey == "已拒绝语音来电", "incoming decline presentation")
        let rejected = begin("rejected", video: true)
        store.finish(rejected, reason: .declined)
        check(try entry("rejected").titleKey == "视频通话被拒绝", "outgoing rejection presentation")
        let failed = begin("failed")
        store.finish(failed, reason: .failed)
        check(try entry("failed").outcome == .failed, "failure records distinct from a completed call")
        let incoming = begin("incoming-completed", incoming: true, video: true)
        store.connected(incoming)
        clock = clock.addingTimeInterval(3661)
        store.finish(incoming, reason: .endedRemotely)
        check(try entry("incoming-completed").formattedDuration == "1:01:01", "long call duration")
        check(try entry("incoming-completed").titleKey == "视频来电", "connected incoming video title")
        check(store.begin(callID: "self", peerID: "fixture-owner", mediaKind: "audio", isIncoming: false) == nil, "self identity cannot create call history")
        check(store.begin(callID: "bad", peerID: "peer", mediaKind: "unknown", isIncoming: false) == nil, "unsupported call kind is rejected")
        let beforeSwitch = try rows().count
        let stale = begin("stale")
        owner = "other-owner"
        store.finish(stale, reason: .endedLocally)
        store.flushPending()
        check(try rows().count == beforeSwitch, "account switch blocks stale call callbacks")
        owner = nil
        check(begin("logged-out") == nil, "logout blocks new records")
        owner = "fixture-owner"
        let orphan = store.begin(callID: "orphan", peerID: "new-peer", mediaKind: "video", isIncoming: true)
        store.finish(orphan, reason: .unanswered)
        check(try rows().contains { $0.chatId.isEmpty }, "metadata survives when invite precedes chat-list refresh")
        let unrelated = Chat(chatId: "unrelated", name: "Other", type: "private", memberIds: ["other-owner", "new-peer"])
        context!.insert(unrelated)
        store.flushPending()
        check(unrelated.messages.isEmpty, "a different owner's chat must not receive a record")
        let newChat = Chat(chatId: "new-chat", name: "New peer", updatedAt: .distantPast, memberIds: ["fixture-owner", "new-peer"])
        context!.insert(newChat)
        store.flushPending()
        check(newChat.messages.count == 1 && newChat.messages[0].chatId == "new-chat", "delayed real chat identity attaches pending metadata")
        let expected = try rows().count
        // Fresh store/container verifies final records survive reopen and dedup
        // does not depend on retaining a call in process memory.
        context = nil
        container = nil
        let reopened = try ModelContainer(for: schema, configurations: config)
        let fresh = ModelContext(reopened)
        check(try fresh.fetch(FetchDescriptor<Message>()).count == expected, "records persist across container reopen")
        let freshStore = CallHistoryStore(owner: { owner }, now: { clock })
        freshStore.configure(fresh)
        let replay = freshStore.begin(callID: "connected", peerID: "peer", mediaKind: "audio", isIncoming: false)
        freshStore.finish(replay, reason: .failed)
        check(try fresh.fetch(FetchDescriptor<Message>()).count == expected, "durable call ID dedup after restart")
        print("PASS: \(checks) real SwiftData call-history checks (fixture clock/events, not CallKit/TRTC device proof)")
    }
}
