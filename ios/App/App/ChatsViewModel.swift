import Foundation
import SwiftData

/// 会话页专用的不可变展示模型。SwiftData `Chat` 仍是本地持久化的权威数据源。
struct ChatConversationModel: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let avatarURL: String?
    let avatarText: String
    let timeString: String
    let unreadCount: Int
    let isGroup: Bool
    let isVerified: Bool
    let isEncrypted: Bool
    let isOnline: Bool
    let lastTimestamp: Date
    let isMuted: Bool
    let isPinned: Bool

    init(chat: Chat, subtitle: String) {
        id = chat.chatId
        title = chat.name
        self.subtitle = subtitle
        avatarURL = chat.avatar
        avatarText = String(chat.name.prefix(1))
        timeString = chat.updatedAt.chatListTimeText
        unreadCount = chat.isMuted ? 0 : chat.unreadCount
        isGroup = chat.type == "group"
        isVerified = chat.isOfficial || chat.isBot
        isEncrypted = chat.isEncrypted
        isOnline = chat.type == "private" && !chat.isOfficial && !chat.isBot
        lastTimestamp = chat.updatedAt
        isMuted = chat.isMuted
        isPinned = chat.isPinned
    }
}

@MainActor
final class IMConversationViewModel: ObservableObject {
    enum Filter: String, CaseIterable {
        case all
        case group
    }

    @Published var searchText = ""
    @Published var filter: Filter = .all
    @Published var isRefreshing = false
    @Published var errorMessage: String?

    func conversations(from chats: [Chat]) -> [ChatConversationModel] {
        filteredChats(from: chats).map { ChatConversationModel(chat: $0, subtitle: displaySubtitle(for: $0)) }
    }

    func filteredChats(from chats: [Chat]) -> [Chat] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return chats
            .filter { chat in
                filter == .all || chat.type == "group"
            }
            .filter { chat in
                keyword.isEmpty
                    || chat.name.localizedCaseInsensitiveContains(keyword)
                    || chat.lastMessage.localizedCaseInsensitiveContains(keyword)
            }
            .sorted { lhs, rhs in
                let leftRank = fixedRank(for: lhs)
                let rightRank = fixedRank(for: rhs)
                if leftRank != rightRank { return leftRank < rightRank }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func totalUnread(in chats: [Chat]) -> Int {
        chats.reduce(0) { $0 + $1.unreadCount }
    }

    func groupUnread(in chats: [Chat]) -> Int {
        chats.filter { $0.type == "group" }.reduce(0) { $0 + $1.unreadCount }
    }

    func togglePinned(_ chat: Chat, modelContext: ModelContext) {
        chat.isPinned.toggle()
        try? modelContext.save()
    }

    private func fixedRank(for chat: Chat) -> Int {
        if chat.isOfficial { return 0 }
        if chat.isBot { return 1 }
        return 99
    }

    func displaySubtitle(for chat: Chat) -> String {
        let content = chat.lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            return "还没有消息"
        }
        if content == "[加密消息]" || content == "🔒 [加密消息]" || content == "🔒 加密消息" || content.contains("等待密钥同步") {
            return "加密消息"
        }
        if content.contains("voice") || content.contains("语音") {
            return "语音"
        }
        if content.contains("sticker") || content.contains("贴纸") {
            return "贴纸"
        }
        if content.contains("image") || content.contains("图片") {
            return "图片"
        }
        if content.contains("file") || content.contains("文件") {
            return "文件"
        }
        return content
    }

    func refresh(chats: [Chat], modelContext: ModelContext) async {
        ensureBuiltinConversations(in: chats, modelContext: modelContext)
        if AuthTokenStore.shared.token == nil {
            return
        }

        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let remoteChats = try await APIClient.shared.fetchChats()
            merge(remoteChats: remoteChats, into: chats, modelContext: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ chat: Chat, modelContext: ModelContext) {
        modelContext.delete(chat)
        try? modelContext.save()
    }

    /// The official account and assistant are product-owned entry points, not
    /// server contacts. A server refresh must never make them disappear.
    func ensureBuiltinConversations(in chats: [Chat], modelContext: ModelContext) {
        var didChange = false
        for (index, sample) in SampleChatData.builtinConversations.enumerated() {
            if let existing = chats.first(where: { $0.chatId == sample.id }) {
                if sample.isOfficial && !existing.isOfficial {
                    existing.isOfficial = true
                    didChange = true
                }
                if sample.isBot && !existing.isBot {
                    existing.isBot = true
                    didChange = true
                }
                if !existing.isPinned {
                    existing.isPinned = true
                    didChange = true
                }
                continue
            }

            let chat = Chat(
                chatId: sample.id,
                name: sample.name,
                type: sample.isGroup ? "group" : "private",
                unreadCount: sample.unreadCount,
                lastMessage: sample.lastMessage,
                updatedAt: Date().addingTimeInterval(TimeInterval(-index * 900)),
                isPinned: sample.isPinned,
                isMuted: sample.isMuted,
                isEncrypted: sample.isEncrypted,
                isOfficial: sample.isOfficial,
                isBot: sample.isBot,
                memberIds: sample.isGroup ? ["me", "lin", "mia", "pm"] : ["me", sample.id]
            )
            let message = Message(
                messageId: UUID().uuidString,
                chatId: chat.chatId,
                senderId: sample.isOutgoing ? "me" : "friend",
                content: sample.lastMessage,
                status: sample.isOutgoing ? "read" : "received",
                createdAt: chat.updatedAt,
                isOutgoing: sample.isOutgoing,
                readAt: sample.isOutgoing ? Date() : nil,
                chat: nil
            )
            chat.messages.append(message)
            modelContext.insert(chat)
            didChange = true
        }
        if didChange { try? modelContext.save() }
    }

    func merge(remoteChats: [RemoteChat], into localChats: [Chat], modelContext: ModelContext) {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")

        for remoteChat in remoteChats {
            if let existing = localChats.first(where: { $0.chatId == remoteChat.id }) {
                existing.name = remoteChat.peer?.nickname ?? remoteChat.peer?.username ?? existing.name
                existing.avatar = remoteChat.peer?.avatar
                existing.unreadCount = remoteChat.unreadCount ?? 0
                existing.lastMessage = remoteChat.lastMessage ?? ""
                existing.updatedAt = Date(milliseconds: remoteChat.lastMessageAt ?? remoteChat.createdAt)
                existing.type = "private"
                existing.isEncrypted = true
                existing.memberIds = [remoteChat.participantA, remoteChat.participantB]
            } else {
                modelContext.insert(remoteChat.toLocalChat(currentUserId: currentUserId))
            }
        }

        try? modelContext.save()
    }

    /// WebSocket 到达新消息时立即更新列表，不等待下一次完整网络刷新。
    func applyRealtimeMessage(_ message: Message, to localChats: [Chat], modelContext: ModelContext) {
        guard let chat = localChats.first(where: { $0.chatId == message.chatId }) else { return }

        chat.lastMessage = previewText(for: message)
        chat.updatedAt = message.createdAt
        if !message.isOutgoing,
           NotificationRouter.shared.activeConversationId != chat.chatId {
            chat.unreadCount += 1
        }
        // The message view already attaches the incoming Message to this chat.
        // SwiftData observes these small metadata mutations and coalesces its
        // own save. Forcing a full save here serializes the whole relationship
        // graph on the UI actor for every WebSocket packet.
    }

    private func previewText(for message: Message) -> String {
        switch message.type {
        case "voice": return "语音"
        case "image": return "图片"
        case "video": return "视频"
        case "sticker", "gif", "meme": return "贴纸"
        case "file": return "文件"
        default:
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == "[加密消息]" || text == "🔒 加密消息" || text.contains("等待密钥同步") {
                return "加密消息"
            }
            return text
        }
    }
}

typealias ChatsViewModel = IMConversationViewModel

private enum SampleChatData {
    struct Conversation {
        let id: String
        let name: String
        let lastMessage: String
        let unreadCount: Int
        let isGroup: Bool
        let isOutgoing: Bool
        let isPinned: Bool
        let isMuted: Bool
        let isEncrypted: Bool
        let isOfficial: Bool
        let isBot: Bool
    }

    static let builtinConversations = [
        Conversation(id: "official", name: "imim 官方", lastMessage: "欢迎使用 imim！点击查看新手指南 →", unreadCount: 0, isGroup: false, isOutgoing: false, isPinned: true, isMuted: false, isEncrypted: true, isOfficial: true, isBot: false),
        Conversation(id: "bot", name: "imim AI", lastMessage: "你好，我是 imim AI，请直接告诉我你的问题。", unreadCount: 0, isGroup: false, isOutgoing: false, isPinned: true, isMuted: false, isEncrypted: true, isOfficial: false, isBot: true),
    ]
}
