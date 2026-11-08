import Foundation
import SwiftData

@main @MainActor
struct ChatSearchRegression {
    static var checks = 0
    static func check(_ value: Bool, _ note: String) {
        if !value { print("FAIL: " + note); fflush(stdout) }
        precondition(value, note); checks += 1
    }
    static func main() throws {
        // Owner supplied in this process's argument domain, never written to defaults.
        check(UserDefaults.standard.string(forKey: "current_user_id") == "fixture-owner", "fixture owner argument domain")
        let container = try ModelContainer(for: User.self, Chat.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1000)
        func call(id: String, owner: String = "fixture-owner", completed: Bool = false) throws -> Message {
            var entry = CallHistoryEntry(ownerID: owner, callID: "internal-call-identifier", peerID: "fixture-peer",
                mediaKind: "video", isIncoming: true, startedAt: start)
            if completed { entry.connectedAt = start.addingTimeInterval(10) }
            entry.endedAt = start.addingTimeInterval(52)
            entry.outcome = completed ? .completed : .missed
            let data = try JSONEncoder().encode(entry)
            let message = Message(messageId: id, chatId: "fixture-chat", senderId: "fixture-peer",
                content: String(decoding: data, as: UTF8.self), type: "call", createdAt: start)
            context.insert(message)
            return message
        }
        let missed = try call(id: "missed")
        let completed = try call(id: "completed", completed: true)
        let other = try call(id: "other", owner: "other-owner")
        let malformed = Message(messageId: "bad", chatId: "fixture-chat", senderId: "fixture-peer", content: "{broken metadata", type: "call")
        let literal = Message(messageId: "literal", chatId: "fixture-chat", senderId: "fixture-peer", content: "Hello **World** — 你好", createdAt: start.addingTimeInterval(10))
        let tie = Message(messageId: "aaa", chatId: "fixture-chat", senderId: "fixture-peer", content: "World", createdAt: literal.createdAt)
        let messages = [missed, completed, other, malformed, literal, tie]
        func rows(_ query: String, _ language: AppLanguage = .english) -> [ChatMessageSearchProjection.Row] {
            ChatMessageSearchProjection.rows(messages: messages, query: query, language: language)
        }
        check(rows("fixture-owner").isEmpty, "internal owner IDs are not searchable call text")
        check(rows("internal-call-identifier").isEmpty, "signaling call IDs are not search results")
        check(rows("mediaKind").isEmpty, "serialized keys are not searchable")
        check(rows("Missed").map(\.id) == ["missed"], "English outcome is searchable")
        check(rows("未接", .simplifiedChinese).map(\.id) == ["missed"], "Chinese outcome is searchable")
        check(rows("00:42").map(\.id) == ["completed"], "connected duration is searchable, excluding ringing")
        check(rows("Missed")[0].text == "Missed video call", "localized missed-call presentation")
        check(rows("00:42")[0].text == "Incoming video call · 00:42", "completed presentation hides metadata")
        check(ChatMessageSearchProjection.displayText(other, language: .english) == nil, "wrong-owner record is hidden")
        check(ChatMessageSearchProjection.displayText(malformed, language: .english) == nil, "malformed record never renders JSON")
        check(rows("world").map(\.id) == ["aaa", "literal"], "case-insensitive matching with deterministic tied dates")
        check(rows("world")[1].message === literal, "row carries the original SwiftData message")
        check(rows("你好")[0].text == literal.content, "user content is preserved verbatim, including markup")
        check(rows("  world  ").count == 2, "trim query whitespace")
        check(rows(" \n ").isEmpty, "whitespace-only query has no results")
        check(rows("world").map(\.id) == rows("world").map(\.id), "repeat projection keeps stable domain IDs")
        print("PASS: \(checks) production chat-search checks with real SwiftData models and bilingual resources; no owner data")
    }
}
