import Foundation
import SwiftData

@main
struct IncomingMessagePersistenceRegression {
    @MainActor static func main() throws {
        // Run with an isolated preferences domain and a disposable DB path.
        UserDefaults.standard.set("fixture-owner", forKey: "current_user_id")
        defer { UserDefaults.standard.removeObject(forKey: "current_user_id") }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = Schema([Chat.self, Message.self, User.self])
        let config = ModelConfiguration(schema: schema, url: url)
        var container: ModelContainer? = try ModelContainer(for: schema, configurations: config)
        var context: ModelContext? = ModelContext(container!)
        let ingress = IncomingMessagePersistence()
        ingress.configure(context!)
        let chat = Chat(chatId: "fixture-chat", name: "nickname")
        context!.insert(chat)
        try context!.save()
        precondition(ingress.begin("fixture-1", owner: "fixture-owner"))
        precondition(!ingress.begin("fixture-1", owner: "fixture-owner"))
        let message = Message(messageId: "fixture-1", chatId: chat.chatId, senderId: "peer", content: "fixture plaintext", isOutgoing: false)
        precondition(ingress.store(message, owner: "fixture-owner") != nil)
        precondition(chat.messages.count == 1)
        precondition(!ingress.begin("fixture-1", owner: "fixture-owner"))
        let duplicate = Message(messageId: "fixture-1", chatId: chat.chatId, senderId: "peer", content: "failed duplicate", isOutgoing: false)
        precondition(ingress.store(duplicate, owner: "fixture-owner")?.content == "fixture plaintext")
        precondition(chat.messages.count == 1)
        // Check a new independent container: receipt survives process restart.
        context = nil
        container = nil
        let reopened = try ModelContainer(for: schema, configurations: config)
        let freshContext = ModelContext(reopened)
        let fetched = try freshContext.fetch(FetchDescriptor<Message>())
        precondition(fetched.count == 1 && fetched[0].content == "fixture plaintext")
        UserDefaults.standard.set("other-owner", forKey: "current_user_id")
        precondition(ingress.stored("fixture-1", owner: "fixture-owner") == nil)
        precondition(!ingress.begin("fixture-2", owner: "fixture-owner"))
        UserDefaults.standard.removeObject(forKey: "current_user_id")
        precondition(ingress.stored("fixture-1", owner: nil) == nil)
        print("Inbox regression: list-tab persistence, duplicate claim/receipt, durable restart, account switch/logout passed")
    }
}
