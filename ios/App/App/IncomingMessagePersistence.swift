import Foundation
import SwiftData

/// A single SwiftData ingress for received private messages, independent of
/// which tab is visible. Never decrypt an already-consumed envelope again.
@MainActor
final class IncomingMessagePersistence {
    static let shared = IncomingMessagePersistence()
    private var context: ModelContext?
    private var inFlight = Set<String>()

    func configure(_ context: ModelContext) { self.context = context }

    func stored(_ id: String, owner: String?) -> Message? {
        guard let owner, owner == UserDefaults.standard.string(forKey: "current_user_id"),
              let context else { return nil }
        var query = FetchDescriptor<Message>(predicate: #Predicate { $0.messageId == id })
        query.fetchLimit = 1
        return try? context.fetch(query).first
    }

    func begin(_ id: String, owner: String?) -> Bool {
        guard let owner, owner == UserDefaults.standard.string(forKey: "current_user_id"),
              context != nil, stored(id, owner: owner) == nil else { return false }
        return inFlight.insert(owner + ":" + id).inserted
    }

    func finish(_ id: String, owner: String?) {
        if let owner { inFlight.remove(owner + ":" + id) }
    }

    @discardableResult
    func store(_ message: Message, owner: String?, saveImmediately: Bool = true) -> Message? {
        defer { finish(message.messageId, owner: owner) }
        guard let owner, owner == UserDefaults.standard.string(forKey: "current_user_id"),
              let context else { return nil }
        if let existing = stored(message.messageId, owner: owner) { return existing }
        context.insert(message)
        let chatID = message.chatId
        var query = FetchDescriptor<Chat>(predicate: #Predicate { $0.chatId == chatID })
        query.fetchLimit = 1
        if let chat = try? context.fetch(query).first {
            // Also attach when receiving on Settings or the conversation list.
            // No new Chat schema, JSON cache or keychain/ratchet access.
            if !chat.messages.contains(where: { $0.messageId == message.messageId }) {
                chat.messages.append(message)
            }
        }
        if saveImmediately {
            do { try context.save() }
            catch { print("[Inbox] SwiftData save failed") }
        }
        return message
    }
}
