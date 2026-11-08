import Foundation
import SwiftData

@main @MainActor struct ReadReceiptRegression {
    static var checks = 0
    static func check(_ value: Bool, _ note: String) {
        guard value else { fatalError("FAIL: \(note)") }; checks += 1
    }
    static func event(chat: String = "private-chat", ids: [String] = ["one"], peer: String? = "peer") -> MessageReadReceipt? {
        MessageReadReceipt.decode(try! JSONSerialization.data(withJSONObject: ["chatId": chat, "messageIds": ids]), from: peer)
    }
    static func main() throws {
        // Process launch arguments provide a volatile owner; never write to App defaults.
        check(UserDefaults.standard.string(forKey: "current_user_id") == "fixture-owner", "isolated launch owner")
        check(event(peer: nil) == nil, "missing authenticated peer rejected")
        check(event(peer: "") == nil, "empty peer rejected")
        check(event(chat: "") == nil, "empty chat rejected")
        check(event(ids: []) == nil, "empty receipt rejected")
        check(event(ids: [""]) == nil, "empty message ID rejected")
        check(event(ids: Array(repeating: "one", count: 10_001)) == nil, "oversized receipt rejected")
        check(MessageReadReceipt.decode(Data("{broken".utf8), from: "peer") == nil, "bad JSON rejected")
        check(MessageReadReceipt.decode(Data(#"{"chatId":"private-chat","messageIds":"one"}"#.utf8), from: "peer") == nil, "wrong message IDs type rejected")
        check(event(ids: ["one", "one"])?.messageIDs.count == 1, "duplicate IDs coalesced")

        let schema = Schema([Chat.self, Message.self, User.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let inbox = IncomingMessagePersistence(); inbox.configure(context)
        let chat = Chat(chatId: "private-chat", name: "fixture")
        chat.memberIds = ["fixture-owner", "peer"]
        context.insert(chat)
        func message(_ id: String, sender: String = "fixture-owner", outgoing: Bool = true, type: String = "text", chatID: String = "private-chat") -> Message {
            let m = Message(messageId: id, chatId: chatID, senderId: sender, content: "fixture", type: type, status: "sent", isOutgoing: outgoing)
            chat.messages.append(m); return m
        }
        let one = message("one"); one.status = "sending"
        let two = message("two", type: "image")
        let incoming = message("incoming", sender: "peer", outgoing: false)
        let call = message("call", type: "call")
        let foreign = message("foreign", sender: "somebody-else")
        let crossChat = message("cross", chatID: "other-chat")
        let untouched = message("untouched")
        try context.save()
        let receipt = event(ids: ["one", "two", "incoming", "call", "foreign", "cross", "unknown"])!
        check(inbox.applyReadReceipt(receipt, owner: nil) == 0, "signed-out receipt ignored")
        check(inbox.applyReadReceipt(receipt, owner: "another-account") == 0, "previous owner ignored")
        check(inbox.applyReadReceipt(event(peer: "stranger")!, owner: "fixture-owner") == 0, "wrong peer ignored")
        check(inbox.applyReadReceipt(event(peer: "fixture-owner")!, owner: "fixture-owner") == 0, "self receipt ignored")
        check(inbox.applyReadReceipt(event(chat: "unknown-chat")!, owner: "fixture-owner") == 0, "missing chat ignored")
        chat.type = "group"
        check(inbox.applyReadReceipt(receipt, owner: "fixture-owner") == 0, "group is never marked all-read")
        chat.type = "private"; chat.isBot = true
        check(inbox.applyReadReceipt(receipt, owner: "fixture-owner") == 0, "AI/bot is not a peer-read receipt")
        chat.isBot = false; chat.isOfficial = true
        check(inbox.applyReadReceipt(receipt, owner: "fixture-owner") == 0, "official account ignored")
        chat.isOfficial = false
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        check(inbox.applyReadReceipt(receipt, owner: "fixture-owner", now: now) == 2, "only matching outgoing messages become read")
        check(one.status == "read" && one.readAt == now, "receipt before ACK can mark outgoing sending item read")
        check(two.status == "read" && two.readAt == now, "image messages share read state")
        check(incoming.readAt == nil && incoming.status == "sent", "incoming is not changed")
        check(call.readAt == nil && foreign.readAt == nil && crossChat.readAt == nil, "call, wrong sender and wrong chat excluded")
        check(untouched.readAt == nil, "unlisted messages do not become read")
        check(inbox.applyReadReceipt(receipt, owner: "fixture-owner", now: now.addingTimeInterval(10)) == 0, "duplicate receipt is idempotent")
        check(one.readAt == now, "duplicate receipt preserves first timestamp")
        let newContext = ModelContext(container)
        let reloaded = try newContext.fetch(FetchDescriptor<Message>()).first { $0.messageId == "one" }
        check(reloaded?.status == "read" && reloaded?.readAt == now, "receipt saved outside visible chat lifecycle")

        check(MessageDeliveryState.resolve(status: "sending", readAt: nil) == .sending, "pending is not read")
        check(MessageDeliveryState.resolve(status: "sent", readAt: nil) == .sent, "sent stays single check without proof")
        check(MessageDeliveryState.resolve(status: "failed", readAt: nil) == .failed, "failed remains failed")
        check(MessageDeliveryState.resolve(status: "read", readAt: nil) == .read, "server read status supported")
        check(MessageDeliveryState.resolve(status: "sent", readAt: now) == .read, "read timestamp supported")
        check(MessageDeliveryState.merging(status: "read", readAt: now, remoteStatus: "sent") == "read", "late ACK cannot regress double check")
        check(MessageDeliveryState.merging(status: "sent", readAt: nil, remoteStatus: "read") == "read", "history read state upgrades sent")
        print("PASS: \(checks) actual receipt parser, SwiftData persistence and delivery-state checks; fixture data only")
    }
}
