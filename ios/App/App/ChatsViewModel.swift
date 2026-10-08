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

/// Transient row input, not another persistence/cache layer. Keep the action
/// target beside its display value so lazy rows never search the entire query.
struct ChatConversationRow: Identifiable {
    let chat: Chat
    let conversation: ChatConversationModel

    var id: String { conversation.id }
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

    func conversationRows(from chats: [Chat]) -> [ChatConversationRow] {
        filteredChats(from: chats).map { chat in
            ChatConversationRow(chat: chat, conversation: ChatConversationModel(chat: chat, subtitle: displaySubtitle(for: chat)))
        }
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
        guard !chat.isBuiltinSystemConversation else { return }
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
            return AppLocalization.string("还没有消息")
        }
        if content == "[加密消息]" || content == "🔒 [加密消息]" || content == "🔒 加密消息" || content.contains("等待密钥同步") {
            return AppLocalization.string("加密消息")
        }
        if content.contains("voice") || content.contains("语音") {
            return AppLocalization.string("语音")
        }
        if content.contains("sticker") || content.contains("贴纸") {
            return AppLocalization.string("贴纸")
        }
        if content.contains("image") || content.contains("图片") {
            return AppLocalization.string("图片")
        }
        if content.contains("file") || content.contains("文件") {
            return AppLocalization.string("文件")
        }
        return content
    }

    func refresh(chats: [Chat], modelContext: ModelContext) async {
        ensureBuiltinConversations(in: chats, modelContext: modelContext)
        // SwiftData paints first; no awaiting disk IO or network downloads here.
        AvatarImageLoader.shared.prefetch(chats.map {
            .init(userId: $0.avatarPeerUserId, urlString: $0.avatar)
        } + [.init(userId: UserDefaults.standard.string(forKey: "current_user_id"),
                   urlString: UserDefaults.standard.string(forKey: "current_user_avatar"))])
        if AuthTokenStore.shared.token == nil {
            return
        }

        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        var refreshErrors: [String] = []

        do {
            let remoteChats = try await APIClient.shared.fetchChats()
            merge(remoteChats: remoteChats, into: chats, modelContext: modelContext)
        } catch {
            refreshErrors.append("私聊：\(error.localizedDescription)")
        }

        if let currentUserId = UserDefaults.standard.string(forKey: "current_user_id"),
           !currentUserId.isEmpty {
            do {
                let remoteGroups = try await APIClient.shared.fetchGroups(userId: currentUserId)
                merge(remoteGroups: remoteGroups, into: chats, modelContext: modelContext)
            } catch {
                refreshErrors.append("群聊：\(error.localizedDescription)")
            }
        } else {
            refreshErrors.append("群聊：缺少当前用户 ID")
        }

        errorMessage = refreshErrors.isEmpty ? nil : refreshErrors.joined(separator: "；")
    }

    func delete(_ chat: Chat, modelContext: ModelContext) {
        guard !chat.isBuiltinSystemConversation else { return }
        modelContext.delete(chat)
        try? modelContext.save()
    }

    /// The official account and assistant are product-owned entry points, not
    /// server contacts. A server refresh must never make them disappear.
    func ensureBuiltinConversations(in chats: [Chat], modelContext: ModelContext) {
        var didChange = false
        for (index, sample) in SampleChatData.builtinConversations.enumerated() {
            if let existing = chats.first(where: { $0.chatId == sample.id }) {
                if existing.avatar != sample.avatar {
                    existing.avatar = sample.avatar
                    didChange = true
                }
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
                avatar: sample.avatar,
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
        AvatarImageLoader.shared.prefetch(remoteChats.map { remote in
            let peerId = currentUserId.flatMap { current in
                [remote.participantA, remote.participantB].first { !$0.isEmpty && $0 != current && $0 != "me" }
            }
            return .init(userId: peerId, urlString: remote.peer?.avatar)
        })
    }

    func merge(remoteGroups: [RemoteGroup], into localChats: [Chat], modelContext: ModelContext) {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")

        for remoteGroup in remoteGroups {
            guard let groupId = remoteGroup.resolvedId else { continue }
            let normalizedName = remoteGroup.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = localChats.first {
                $0.chatId == groupId || $0.chatId == "group_\(groupId)"
            }
            let timestamp = remoteGroup.updatedAt ?? remoteGroup.createdAt

            if let existing {
                if let normalizedName, !normalizedName.isEmpty {
                    existing.name = normalizedName
                }
                if let avatar = remoteGroup.avatar {
                    existing.avatar = avatar
                }
                existing.type = "group"
                existing.unreadCount = remoteGroup.unreadCount ?? existing.unreadCount
                if let lastMessage = remoteGroup.lastMessage, !lastMessage.isEmpty {
                    existing.lastMessage = lastMessage
                }
                if let timestamp {
                    existing.updatedAt = Date(milliseconds: timestamp)
                }
                existing.isEncrypted = true
                if let currentUserId, !existing.memberIds.contains(currentUserId) {
                    existing.memberIds.append(currentUserId)
                }
            } else {
                modelContext.insert(Chat(
                    chatId: groupId,
                    name: normalizedName.flatMap { $0.isEmpty ? nil : $0 } ?? "未命名群聊",
                    avatar: remoteGroup.avatar,
                    type: "group",
                    unreadCount: remoteGroup.unreadCount ?? 0,
                    lastMessage: remoteGroup.lastMessage ?? "",
                    updatedAt: timestamp.map { Date(milliseconds: $0) } ?? Date(),
                    isEncrypted: true,
                    memberIds: currentUserId.map { [$0] } ?? []
                ))
            }
        }

        try? modelContext.save()
        AvatarImageLoader.shared.prefetch(remoteGroups.map {
            .init(userId: nil, urlString: $0.avatar)
        })
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

extension Chat {
    var isBuiltinSystemConversation: Bool {
        chatId == "official" || chatId == "bot"
    }
}

private enum SampleChatData {
    struct Conversation {
        let id: String
        let name: String
        let avatar: String
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
        Conversation(id: "official", name: "imim 官方", avatar: "asset://ImimOfficialAvatar", lastMessage: "欢迎使用 imim！点击查看新手指南 →", unreadCount: 0, isGroup: false, isOutgoing: false, isPinned: true, isMuted: false, isEncrypted: true, isOfficial: true, isBot: false),
        Conversation(id: "bot", name: "imim AI", avatar: "asset://ImimAIAvatar", lastMessage: "你好，我是 imim AI，请直接告诉我你的问题。", unreadCount: 0, isGroup: false, isOutgoing: false, isPinned: true, isMuted: false, isEncrypted: true, isOfficial: false, isBot: true),
    ]
}
