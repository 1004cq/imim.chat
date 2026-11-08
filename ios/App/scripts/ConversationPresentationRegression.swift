import Foundation
import SwiftData
import SwiftUI

@main
struct ConversationPresentationRegression {
    @MainActor
    static func main() throws {
        let container = try ModelContainer(for: Chat.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let model = IMConversationViewModel()
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label)
            checks += 1
            print("PASS: \(label)")
        }
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let official = Chat(chatId: "official", name: "imim 官方", updatedAt: base, isPinned: true, isOfficial: true)
        let bot = Chat(chatId: "bot", name: "imim AI", updatedAt: base, isPinned: true, isBot: true)
        let peer = Chat(chatId: "peer-a", name: "Alice", avatar: "https://example.invalid/a?v=1",
            unreadCount: 3, lastMessage: "fixture greeting", updatedAt: base.addingTimeInterval(20), memberIds: ["me", "alice"])
        let group = Chat(chatId: "group-a", name: "Fixture Group", type: "group", unreadCount: 4,
            lastMessage: "fixture keyword", updatedAt: base.addingTimeInterval(10))
        let muted = Chat(chatId: "muted-a", name: "Muted", unreadCount: 9,
            lastMessage: "[加密消息]", updatedAt: base.addingTimeInterval(30), isMuted: true)
        let chats = [group, peer, bot, muted, official]
        for chat in chats { context.insert(chat) }
        try context.save()

        var rows = model.conversationRows(from: chats)
        check(rows.map(\.id) == ["official", "bot", "muted-a", "peer-a", "group-a"], "fixed accounts and recency retain existing order")
        for row in rows {
            check(row.chat === chats.first(where: { $0.chatId == row.id }), "row action target is original SwiftData object")
            check(row.conversation == ChatConversationModel(chat: row.chat, subtitle: model.displaySubtitle(for: row.chat)), "display fields match current model")
        }
        check(rows.first(where: { $0.id == "muted-a" })?.conversation.unreadCount == 0, "muted badge behavior preserved")
        check(model.groupUnread(in: chats) == 4, "group unread total preserved")
        check(rows.first(where: { $0.id == "peer-a" })?.chat.memberIds == ["me", "alice"], "avatar peer identity inputs preserved")
        check(model.conversationRows(from: []).isEmpty, "empty query has no phantom rows")

        model.filter = .group
        check(model.conversationRows(from: chats).map(\.id) == ["group-a"], "group filter keeps only groups")
        model.filter = .all
        model.searchText = "  aLiCe  "
        check(model.conversationRows(from: chats).map(\.id) == ["peer-a"], "case-insensitive trimmed title search preserved")
        model.searchText = "keyword"
        check(model.conversationRows(from: chats).map(\.id) == ["group-a"], "message-preview search preserved")
        model.searchText = "no fixture matches"
        check(model.conversationRows(from: chats).isEmpty, "unmatched search remains empty")
        model.searchText = ""

        model.togglePinned(group, modelContext: context)
        check(model.conversationRows(from: chats).map(\.id) == ["official", "bot", "group-a", "muted-a", "peer-a"], "pin action on carried target reorders ordinary row")
        model.togglePinned(group, modelContext: context)
        model.togglePinned(official, modelContext: context)
        model.togglePinned(bot, modelContext: context)
        check(official.isPinned && bot.isPinned, "built-in pin guard preserved")
        model.delete(official, modelContext: context)
        model.delete(bot, modelContext: context)
        let retainedCount = try context.fetchCount(FetchDescriptor<Chat>())
        check(retainedCount == 5, "built-in delete guard preserved")

        let originalRows = model.conversationRows(from: chats)
        peer.name = "Updated Alice"
        peer.avatar = "https://example.invalid/a?v=2"
        peer.unreadCount = 7
        peer.lastMessage = "updated fixture text"
        peer.updatedAt = base.addingTimeInterval(100)
        rows = model.conversationRows(from: chats)
        let updated = rows.first { $0.id == "peer-a" }!
        check(updated.chat === peer && updated.id == "peer-a", "metadata update keeps target and stable identity")
        check(updated.conversation.title == "Updated Alice" && updated.conversation.subtitle == "updated fixture text", "fresh projection observes title and preview mutation")
        check(updated.conversation.avatarURL?.hasSuffix("v=2") == true && updated.conversation.unreadCount == 7, "fresh projection observes avatar and unread mutation")
        check(rows.map(\.id) == ["official", "bot", "peer-a", "muted-a", "group-a"], "realtime timestamp-like mutation reorders correctly")
        check(rows.first { $0.id == "group-a" }?.conversation == originalRows.first { $0.id == "group-a" }?.conversation, "unrelated display value remains equal")
        check(originalRows.first { $0.id == "peer-a" }?.conversation.title == "Alice", "previous display value is immutable, not a persistent cache")

        let oldLanguage = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(oldLanguage, forKey: AppLanguage.preferenceKey) }
        for language in [AppLanguage.simplifiedChinese, .english] {
            UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            let localized = model.conversationRows(from: chats)
            check(localized.first { $0.id == "muted-a" }?.conversation.subtitle == AppLocalization.string("加密消息"), "new projection uses selected language: \(language.rawValue)")
            let expectedSubtitle = language == .english ? "Encrypted message" : "加密消息"
            check(localized.first { $0.id == "muted-a" }?.conversation.subtitle == expectedSubtitle, "compiled translation resource is used: \(language.rawValue)")
            check(localized.first { $0.id == "peer-a" }?.conversation.title == "Updated Alice", "language switch does not translate user title: \(language.rawValue)")
        }

        // Malformed input must not introduce a trapping Dictionary initializer.
        // ForEach's existing duplicate-ID limitation is not a schema migration.
        let duplicate = Chat(chatId: "peer-a", name: "Duplicate fixture", updatedAt: base)
        let duplicateRows = model.conversationRows(from: [peer, duplicate])
        check(duplicateRows.count == 2, "duplicate fixture does not trap or silently drop data")
        check(duplicateRows[0].chat === peer && duplicateRows[1].chat === duplicate, "duplicate fixture keeps each display/action association coherent")
        model.delete(group, modelContext: context)
        let remaining = try context.fetch(FetchDescriptor<Chat>())
        check(!model.conversationRows(from: remaining).contains { $0.id == "group-a" }, "delete carried target removes the corresponding query row")

        // Compare only projection/data association, not SwiftUI rendering/FPS.
        let fixtures = (0..<500).map { Chat(chatId: "bench-\($0)", name: "Fixture \($0)", updatedAt: base.addingTimeInterval(Double($0))) }
        func elapsed(_ work: () -> Int) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            let count = work()
            precondition(count == 500)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func legacyModels() -> [ChatConversationModel] {
            model.filteredChats(from: fixtures).map { ChatConversationModel(chat: $0, subtitle: model.displaySubtitle(for: $0)) }
        }
        // Mirror pre-A1 isEmpty + iteration (unique-ID fixtures).
        func legacyPass() -> Int {
            if legacyModels().isEmpty { return 0 }
            return legacyModels().reduce(0) { count, value in
                count + (fixtures.first { $0.chatId == value.id } == nil ? 0 : 1)
            }
        }
        _ = legacyPass()
        _ = model.conversationRows(from: fixtures)
        let before = (0..<7).map { _ in elapsed(legacyPass) }.sorted()[3]
        let after = (0..<7).map { _ in elapsed {
            model.conversationRows(from: fixtures).reduce(0) { count, row in
                count + (row.chat.chatId == row.id ? 1 : 0)
            }
        } }.sorted()[3]
        print("METRIC: 500 actual SwiftData fixtures; Mac warm median; legacy_double_projection_ms=\(before); A1_single_projection_ms=\(after); NOT UI/FPS")
        print("CONVERSATION PRESENTATION REGRESSION: \(checks) checks passed")
    }
}
