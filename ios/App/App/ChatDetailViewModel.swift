import Foundation
import SwiftData

struct AICompletedReply: Equatable {
    let id: String
    let ownerID: String
    let text: String
}

// MARK: Release chat concurrency
/// Structured deadline: scope exit cancels and joins the losing child.
/// Preparation errors and parent cancellation retain their original semantics.
enum ChatAsyncDeadline {
    static func run(timeout: Duration = .seconds(5),
                    operation: @escaping @Sendable () async throws -> Bool) async throws -> Bool {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: Bool?.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            let result = try await group.next()
            try Task.checkCancellation()
            return result.flatMap { $0 } ?? false
        }
    }
}
// MARK: End release chat concurrency

@MainActor
final class ChatDetailViewModel: ObservableObject {
    @Published var isShowingAttachmentPanel = false
    @Published var isLoadingMessages = false
    @Published var isSending = false
    @Published private(set) var sendingMessageStatus: String?
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var replyingTo: Message?
    @Published var voiceInputLockedUntil = Date.distantPast
    @Published var isShowingAIConsent = false
    @Published private(set) var completedAIReply: AICompletedReply?
    private var pendingAIText: String?
    private var pendingAIOwner: String?
    private var aiTask: Task<Void, Never>?
    // Presentation metadata only; no schema change or message plaintext cache.
    @Published private(set) var senderAvatars: [String: AvatarImageLoader.Source] = [:]

    var canStartVoiceInput: Bool {
        Date() >= voiceInputLockedUntil && !isSending
    }

    private struct MessageSortKey: Equatable {
        let object: ObjectIdentifier
        let id: String
        let createdAt: Date
        let senderID: String
        let isAIWelcome: Bool
    }
    private struct MessageSortSnapshot: Equatable {
        let chatObject: ObjectIdentifier
        let chatID: String
        let ownerID: String?
        let items: [MessageSortKey]
    }
    private var encryptedRetryTicket = UUID()
    private var sortedMessagesCache: (snapshot: MessageSortSnapshot, result: [Message])?

    func sortedMessages(for chat: Chat) -> [Message] {
        let owner = UserDefaults.standard.string(forKey: "current_user_id")
        let snapshot = MessageSortSnapshot(chatObject: ObjectIdentifier(chat), chatID: chat.chatId,
            ownerID: owner, items: chat.messages.map {
                MessageSortKey(object: ObjectIdentifier($0), id: $0.messageId, createdAt: $0.createdAt,
                    senderID: $0.senderId,
                    isAIWelcome: $0.senderId == "friend" && $0.content == "你好，我是 imim AI，请直接告诉我你的问题。")
            })
        if let cached = sortedMessagesCache, cached.snapshot == snapshot { return cached.result }
        // Stable ties preserve relationship order; objects stay on their owning actor/context.
        let sorted = chat.messages.enumerated().sorted {
            $0.element.createdAt == $1.element.createdAt ? $0.offset < $1.offset : $0.element.createdAt < $1.element.createdAt
        }.map(\.element)
        let result: [Message]
        if AIConversation.matches(chat.chatId) {
            if let owner, !owner.isEmpty {
                result = sorted.filter {
                    $0.messageId.hasPrefix(AIConversation.messagePrefix(owner: owner)) ||
                    ($0.senderId == "friend" && $0.content == "你好，我是 imim AI，请直接告诉我你的问题。")
                }
            } else { result = [] }
        } else { result = sorted }
        sortedMessagesCache = (snapshot, result)
        return result
    }

    // A successful sync can suppress only this owner's ordinary refreshes.
    // Explicit recovery continues to call forceBundleRegistration directly.
    private var lastE2EESync: (owner: String, token: String?, date: Date)?
    private func synchronizeE2EEIfNeeded() async throws {
        try Task.checkCancellation()
        guard let owner = UserDefaults.standard.string(forKey: "current_user_id"), !owner.isEmpty else {
            throw APIClientError.server("缺少当前用户 ID，无法读取消息")
        }
        let token = AuthTokenStore.shared.token
        let now = Date()
        if let previous = lastE2EESync, previous.owner == owner, previous.token == token,
           (0..<60).contains(now.timeIntervalSince(previous.date)) { return }
        try await E2EEManager.shared.synchronizeCurrentUser()
        try Task.checkCancellation()
        guard owner == UserDefaults.standard.string(forKey: "current_user_id"), token == AuthTokenStore.shared.token else {
            throw CancellationError()
        }
        lastE2EESync = (owner, token, Date())
    }

    func beginReply(to message: Message) {
        replyingTo = message
    }

    func cancelReply() {
        replyingTo = nil
    }

    func loadMessages(for chat: Chat, modelContext: ModelContext) async {
        if AIConversation.matches(chat.chatId) { errorMessage = nil; noticeMessage = nil; return }
        guard AuthTokenStore.shared.token != nil else { return }

        isLoadingMessages = true
        errorMessage = nil
        noticeMessage = nil
        defer { isLoadingMessages = false }

        do {
            if chat.type == "group" {
                guard let currentUserId = UserDefaults.standard.string(forKey: "current_user_id"),
                      !currentUserId.isEmpty else {
                    throw APIClientError.server("缺少当前用户 ID，无法读取群消息")
                }
                let groupID = chat.chatId
                let hasMLSState = try await ChatAsyncDeadline.run {
                    try await MLSGroupManager.shared.prepareGroup(
                        groupId: groupID, userId: currentUserId, waitForWelcome: true)
                }
                if !hasMLSState {
                    noticeMessage = MLSGroupError.waitingForExistingDevice.localizedDescription
                }
                let response = try await APIClient.shared.fetchGroupMessages(
                    groupId: chat.chatId,
                    userId: currentUserId
                )
                rememberSenderAvatars(response.messages.map {
                    .init(userId: $0.senderId, urlString: $0.senderAvatar, name: $0.senderName)
                })
                await merge(groupMessages: response.messages, into: chat, currentUserId: currentUserId)
                try await APIClient.shared.acknowledgeGroupMessages(
                    groupId: chat.chatId,
                    userId: currentUserId,
                    lastAckSeq: response.latestSeq
                )
            } else {
                try await synchronizeE2EEIfNeeded()
                let remoteMessages = try await APIClient.shared.fetchMessages(chatId: chat.chatId)
                rememberSenderAvatars(remoteMessages.map {
                    .init(userId: $0.senderId, urlString: $0.senderAvatar, name: $0.senderName)
                })
                await merge(remoteMessages: remoteMessages, into: chat)
            }
            chat.unreadCount = 0
            save(modelContext)
        } catch {
            let nsError = error as NSError
            guard !(error is CancellationError), !Task.isCancelled,
                  !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func rememberSenderAvatars(_ sources: [AvatarImageLoader.Source]) {
        var next = senderAvatars
        for source in sources {
            guard let id = source.userId, !id.isEmpty,
                  source.urlString != nil || source.name != nil else { continue }
            next[id] = source
        }
        if next != senderAvatars { senderAvatars = next }
        // Message snapshots cannot roll back a newer contact/profile avatar.
        AvatarImageLoader.shared.prefetch(sources, allowsSourceUpdates: false)
    }

    /// A retry for ciphertext that was encrypted to a discarded device key
    /// must create a new ratchet. Reloading the same ciphertext cannot recover
    /// a private key that is no longer on this device.
    func retryEncryptedMessage(_ message: Message, in chat: Chat, modelContext: ModelContext) async {
        guard !Task.isCancelled, !AIConversation.matches(chat.chatId), !isLoadingMessages, !isSending,
              message.chatId == chat.chatId else { return }
        if chat.type == "group" {
            await loadMessages(for: chat, modelContext: modelContext)
            return
        }
        guard let owner = UserDefaults.standard.string(forKey: "current_user_id"),
              let token = AuthTokenStore.shared.token else { return }
        let ticket = UUID()
        encryptedRetryTicket = ticket
        isLoadingMessages = true
        errorMessage = nil
        noticeMessage = nil
        defer { if encryptedRetryTicket == ticket { isLoadingMessages = false } }
        func current() -> Bool {
            !Task.isCancelled && encryptedRetryTicket == ticket &&
                owner == UserDefaults.standard.string(forKey: "current_user_id") && token == AuthTokenStore.shared.token
        }
        do {
            var before: String?
            var selected: RemoteMessage?
            for _ in 0..<4 {
                let page = try await APIClient.shared.fetchMessages(chatId: chat.chatId, before: before, limit: 100)
                guard current() else { return }
                if let match = page.first(where: { $0.id == message.messageId }) { selected = match; break }
                guard let oldest = page.min(by: { $0.createdAt < $1.createdAt }), oldest.id != before else { break }
                before = oldest.id
            }
            guard let remote = selected, remote.msgType == "encrypted", remote.senderId != owner else {
                noticeMessage = "暂未找到可重试的密文，请从聊天记录中重新打开后重试"
                return
            }
            let resolved = await remote.toLocalMessageResolvingEncryption(currentUserId: owner, persistSession: false)
            guard current() else { return }
            guard !resolved.content.contains("等待密钥同步") else {
                noticeMessage = "当前保存的密钥仍无法解密这条消息，请让对方重新发送。重试不会重建或覆盖当前会话。"
                return
            }
            message.content = resolved.content
            message.type = resolved.type
            message.mediaURL = resolved.mediaURL
            message.voiceURL = resolved.voiceURL
            message.voiceDuration = resolved.voiceDuration
            message.voiceWaveform = resolved.voiceWaveform
            message.fileName = resolved.fileName
            message.fileSize = resolved.fileSize
            message.mimeType = resolved.mimeType
            message.stickerURL = resolved.stickerURL
            message.stickerEmoji = resolved.stickerEmoji
            message.stickerName = resolved.stickerName
            message.stickerFormat = resolved.stickerFormat
            message.stickerThumbURL = resolved.stickerThumbURL
            message.stickerPackID = resolved.stickerPackID
            noticeMessage = "已重新解密这条消息"
            save(modelContext)
        } catch {
            guard current() else { return }
            let ns = error as NSError
            if error is CancellationError || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) { return }
            errorMessage = error.localizedDescription
        }
    }

    func recoverEncryptionSession(for chat: Chat, modelContext: ModelContext) async {
        guard !AIConversation.matches(chat.chatId) else { return }
        guard chat.type != "group" else {
            errorMessage = "群聊使用 MLS 密钥，不能用私聊安全会话重置功能恢复"
            return
        }
        guard let peerId = peerUserId(for: chat) else {
            errorMessage = "缺少对方用户 ID，无法重建加密会话"
            return
        }

        errorMessage = nil
        noticeMessage = nil
        do {
            try await E2EEManager.shared.resetSession(with: peerId)
            try await E2EEManager.shared.synchronizeCurrentUser(forceBundleRegistration: true)
            SocketManager.shared.requestEncryptionSessionReset(with: peerId)
            noticeMessage = "已将这台手机的新密钥同步到服务器；请让对方发送一条新消息以重新建立加密会话。"
            save(modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updatePrivacy(
        in chat: Chat,
        vanishMode: Bool,
        vanishSeconds: Int? = nil,
        restrictForwarding: Bool,
        modelContext: ModelContext
    ) async {
        guard chat.type != "group" else {
            errorMessage = "群聊不支持私聊的消失消息与转发限制设置"
            return
        }
        guard AuthTokenStore.shared.token != nil else {
            errorMessage = "请先登录后再修改会话安全设置"
            return
        }
        do {
            let privacy = try await APIClient.shared.updateChatPrivacy(
                chatId: chat.chatId,
                vanishMode: vanishMode,
                vanishSeconds: vanishSeconds,
                restrictForwarding: restrictForwarding
            )
            chat.vanishMode = privacy.vanishMode
            chat.vanishSeconds = privacy.vanishSeconds
            chat.restrictForwarding = privacy.restrictForwarding
            save(modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendMessage(_ content: String, in chat: Chat, modelContext: ModelContext) async {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        if AIConversation.matches(chat.chatId) {
            AIFlowTrace.record(.sendTapped)
            guard !isSending else { return }
            guard content.count <= 6000 else { errorMessage = "每条 AI 消息最多 6000 字符"; return }
            guard hasAIConsent else {
                pendingAIText = content; pendingAIOwner = UserDefaults.standard.string(forKey: "current_user_id")
                isShowingAIConsent = true; return
            }
            aiTask = Task { await self.sendAIText(content, in: chat, modelContext: modelContext) }
            await aiTask?.value
            return
        }
        if chat.type == "group" {
            _ = await sendGroupTextMessage(content, in: chat, modelContext: modelContext)
            return
        }
        let tempId = UUID().uuidString
        let peerId = peerUserId(for: chat)

        let tempMessage = Message(
            messageId: tempId,
            chatId: chat.chatId,
            senderId: UserDefaults.standard.string(forKey: "current_user_id") ?? "me",
            content: content,
            type: "text",
            status: "sending",
            createdAt: Date(),
            isOutgoing: true,
            burnAfterRead: chat.vanishMode ? chat.vanishSeconds : nil,
            forwardRestricted: chat.restrictForwarding,
            chat: nil
        )

        chat.messages.append(tempMessage)
        chat.lastMessage = content
        chat.updatedAt = tempMessage.createdAt
        voiceInputLockedUntil = Date().addingTimeInterval(0.7)
        let replyToId = replyingTo?.messageId
        replyingTo = nil
        isShowingAttachmentPanel = false
        // Keep the optimistic bubble in memory while encryption and transport
        // begin. Saving the whole SwiftData graph here blocked the keyboard;
        // the result path below persists the same message on success or failure.

        guard AuthTokenStore.shared.token != nil else {
            tempMessage.status = "failed"
            errorMessage = "未登录，无法建立端到端加密会话"
            save(modelContext)
            return
        }

        guard let peerId else {
            tempMessage.status = "failed"
            errorMessage = "缺少对方用户 ID，无法建立端到端加密会话"
            save(modelContext)
            return
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let encryptedEnvelope = try await E2EEManager.shared.encryptText(content, peerId: peerId)
            let remoteMessage = try await APIClient.shared.sendMessage(chatId: chat.chatId, encryptedEnvelope: encryptedEnvelope, replyToId: replyToId,
                notificationText: chat.vanishMode ? nil : content)
            let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
            apply(remoteMessage, to: tempMessage, currentUserId: currentUserId)
            tempMessage.content = content
            tempMessage.type = "text"
            chat.lastMessage = previewText(for: tempMessage)
            chat.updatedAt = tempMessage.createdAt
            save(modelContext)
        } catch {
            tempMessage.status = "failed"
            errorMessage = error.localizedDescription
            save(modelContext)
        }
    }

    /// A group draft is accepted only after an outgoing bubble exists. Missing
    /// group keys must not silently consume the composer's input text.
    func submitComposerMessage(_ content: String, in chat: Chat, modelContext: ModelContext) async -> Bool {
        guard !isSending, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if chat.type == "group" {
            return await sendGroupTextMessage(content, in: chat, modelContext: modelContext)
        }
        await sendMessage(content, in: chat, modelContext: modelContext)
        return true
    }

    private var aiConsentKey: String { "imim.ai.deepseek.consent.v1." + (UserDefaults.standard.string(forKey: "current_user_id") ?? "") }
    private var hasAIConsent: Bool { UserDefaults.standard.bool(forKey: aiConsentKey) }

    func confirmAIConsent(in chat: Chat, modelContext: ModelContext) async {
        guard AIConversation.matches(chat.chatId), let text = acceptAIConsent() else { return }
        await sendMessage(text, in: chat, modelContext: modelContext)
    }

    func acceptAIConsent() -> String? {
        guard pendingAIOwner == UserDefaults.standard.string(forKey: "current_user_id"), let text = pendingAIText else { return nil }
        pendingAIText = nil; pendingAIOwner = nil
        isShowingAIConsent = false
        UserDefaults.standard.set(true, forKey: aiConsentKey)
        AIFlowTrace.record(.consentAccepted)
        return text
    }

    func cancelAIConsent() -> String {
        let text = pendingAIOwner == UserDefaults.standard.string(forKey: "current_user_id") ? pendingAIText ?? "" : ""
        pendingAIText = nil; pendingAIOwner = nil; isShowingAIConsent = false
        return text
    }
    func cancelAIRequest() { aiTask?.cancel(); completedAIReply = nil; pendingAIText = nil; pendingAIOwner = nil; isShowingAIConsent = false }

    private func sendAIText(_ text: String, in chat: Chat, modelContext: ModelContext) async {
        guard !Task.isCancelled, !isSending, let owner = UserDefaults.standard.string(forKey: "current_user_id"), !owner.isEmpty,
              let token = AuthTokenStore.shared.token else { errorMessage = "请先登录"; return }
        isSending = true; errorMessage = nil; replyingTo = nil; completedAIReply = nil
        AIFlowTrace.record(.requestStarted)
        defer { isSending = false; aiTask = nil }
        let messagePrefix = AIConversation.messagePrefix(owner: owner)
        var turns = sortedMessages(for: chat)
            .filter { $0.chatId == chat.chatId && $0.type == "text" && $0.status != "failed" && $0.status != "sending" &&
                [$0.isOutgoing ? owner : "BOT"].contains($0.senderId) && !$0.content.isEmpty && $0.content.count <= 6000 }
            .suffix(19).map { AIChatTurn(role: $0.senderId == "BOT" ? "assistant" : "user", content: $0.content) }
        turns.append(AIChatTurn(role: "user", content: text))
        while turns.count > 1 && turns.reduce(0, { $0 + $1.content.count }) > 24_000 { turns.removeFirst() }
        let outgoing = Message(messageId: messagePrefix + UUID().uuidString, chatId: chat.chatId, senderId: owner,
            content: text, type: "text", status: "sending", createdAt: Date(), isOutgoing: true, chat: nil)
        let reply = Message(messageId: messagePrefix + UUID().uuidString, chatId: chat.chatId, senderId: "BOT",
            content: "", type: "text", status: "sending", createdAt: Date(), isOutgoing: false, chat: nil)
        chat.messages.append(contentsOf: [outgoing, reply])
        // The built-in Chat row is shared across accounts in this legacy store.
        // Do not leave one account's AI text in that shared list preview.
        chat.lastMessage = "imim AI · DeepSeek"
        let current = { UserDefaults.standard.string(forKey: "current_user_id") == owner && AuthTokenStore.shared.token == token }
        do {
            var receivedFirstDelta = false
            let result = try await APIClient.shared.streamAIReply(turns: turns) { partial in
                guard current(), !Task.isCancelled else { return }
                if !receivedFirstDelta { receivedFirstDelta = true; AIFlowTrace.record(.firstDelta) }
                reply.content = partial
            }
            guard current(), !Task.isCancelled else { return }
            reply.content = result; reply.status = "received"; outgoing.status = "sent"
            chat.lastMessage = "imim AI · DeepSeek"; chat.updatedAt = reply.createdAt
            save(modelContext)
            completedAIReply = AICompletedReply(id: reply.messageId, ownerID: owner, text: result)
            AIFlowTrace.record(.requestCompleted)
        } catch {
            guard current() else { return }
            AIFlowTrace.record(error is CancellationError || Task.isCancelled ? .requestCancelled : .requestFailed)
            outgoing.status = "failed"; reply.status = "failed"
            if reply.content.isEmpty { reply.content = "AI 未完成回复，请重试" }
            errorMessage = error is CancellationError ? nil : error.localizedDescription
            save(modelContext)
        }
    }

    func sendSticker(_ item: StickerItem, from pack: StickerPack?, in chat: Chat, modelContext: ModelContext) async {
        guard !AIConversation.matches(chat.chatId) else { errorMessage = "imim AI 目前仅支持文字消息"; return }
        guard chat.type != "group" else {
            errorMessage = groupEncryptionUnavailableMessage
            return
        }
        if item.isEmoji {
            let emoji = item.emoji?.isEmpty == false ? item.emoji! : "🙂"
            await sendMessage(emoji, in: chat, modelContext: modelContext)
            return
        }

        guard let stickerURL = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !stickerURL.isEmpty else {
            errorMessage = "该贴纸没有可用资源"
            return
        }

        let isGIF = item.isGIF
        let originalType = isGIF ? "image" : "sticker"
        let label = isGIF ? "[GIF]" : "[贴纸] \(item.emoji ?? "")"
        let tempMessage = Message(
            messageId: UUID().uuidString,
            chatId: chat.chatId,
            senderId: UserDefaults.standard.string(forKey: "current_user_id") ?? "me",
            content: label,
            type: originalType,
            mediaURL: isGIF ? stickerURL : nil,
            stickerURL: stickerURL,
            stickerEmoji: item.emoji,
            stickerName: pack?.name ?? item.packName ?? item.name,
            stickerFormat: item.normalizedFormat,
            stickerThumbURL: item.thumbUrl,
            stickerPackID: pack?.id ?? item.packId,
            status: "sending",
            createdAt: Date(),
            isOutgoing: true,
            burnAfterRead: chat.vanishMode ? chat.vanishSeconds : nil,
            forwardRestricted: chat.restrictForwarding,
            chat: nil
        )

        chat.messages.append(tempMessage)
        chat.lastMessage = previewText(for: tempMessage)
        chat.updatedAt = tempMessage.createdAt
        isShowingAttachmentPanel = false
        save(modelContext)

        guard AuthTokenStore.shared.token != nil else {
            tempMessage.status = "failed"
            errorMessage = "未登录，无法加密发送贴纸"
            save(modelContext)
            return
        }
        guard let peerId = peerUserId(for: chat) else {
            tempMessage.status = "failed"
            errorMessage = "缺少对方用户 ID，无法建立端到端加密会话"
            save(modelContext)
            return
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        var extra: [String: Any] = [
            "stickerUrl": stickerURL,
            "stickerEmoji": item.emoji ?? "",
            "stickerSetName": pack?.name ?? item.packName ?? item.name ?? "贴纸",
            "stickerFormat": item.normalizedFormat,
            "stickerId": item.id
        ]
        if let packID = pack?.id ?? item.packId { extra["stickerPackId"] = packID }
        if let thumbURL = item.thumbUrl, !thumbURL.isEmpty { extra["thumbUrl"] = thumbURL }
        if isGIF { extra["imageUrl"] = stickerURL }

        do {
            let encryptedEnvelope = try await E2EEManager.shared.encryptText(label, peerId: peerId)
            let remoteMessage = try await APIClient.shared.sendMessage(
                chatId: chat.chatId,
                encryptedEnvelope: encryptedEnvelope,
                extra: extra,
                notificationText: chat.vanishMode ? nil : "[贴纸]"
            )
            let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
            apply(remoteMessage, to: tempMessage, currentUserId: currentUserId)
            // Keep the local rendering metadata if an older server omits newly added fields.
            tempMessage.content = label
            tempMessage.type = originalType
            tempMessage.mediaURL = isGIF ? (tempMessage.mediaURL ?? stickerURL) : tempMessage.mediaURL
            tempMessage.stickerURL = tempMessage.stickerURL ?? stickerURL
            tempMessage.stickerEmoji = tempMessage.stickerEmoji ?? item.emoji
            tempMessage.stickerName = tempMessage.stickerName ?? pack?.name ?? item.packName ?? item.name
            tempMessage.stickerFormat = tempMessage.stickerFormat ?? item.normalizedFormat
            tempMessage.stickerThumbURL = tempMessage.stickerThumbURL ?? item.thumbUrl
            tempMessage.stickerPackID = tempMessage.stickerPackID ?? pack?.id ?? item.packId
            chat.lastMessage = previewText(for: tempMessage)
            chat.updatedAt = tempMessage.createdAt
            save(modelContext)
        } catch {
            tempMessage.status = "failed"
            errorMessage = error.localizedDescription
            save(modelContext)
        }
    }

    func sendVoiceMessage(_ recording: VoiceRecordingResult, in chat: Chat, modelContext: ModelContext) async {
        guard !AIConversation.matches(chat.chatId) else { errorMessage = "imim AI 目前仅支持文字消息"; return }
        guard chat.type != "group" else {
            errorMessage = groupEncryptionUnavailableMessage
            return
        }
        let tempId = UUID().uuidString
        let tempMessage = Message(
            messageId: tempId,
            chatId: chat.chatId,
            senderId: UserDefaults.standard.string(forKey: "current_user_id") ?? "me",
            content: "[语音消息]",
            type: "voice",
            voiceURL: recording.fileURL.absoluteString,
            voiceDuration: recording.duration,
            voiceWaveform: recording.waveform,
            status: "sending",
            createdAt: Date(),
            isOutgoing: true,
            burnAfterRead: chat.vanishMode ? chat.vanishSeconds : nil,
            forwardRestricted: chat.restrictForwarding,
            chat: nil
        )

        chat.messages.append(tempMessage)
        chat.lastMessage = "[语音消息]"
        chat.updatedAt = tempMessage.createdAt
        isShowingAttachmentPanel = false
        save(modelContext)

        guard AuthTokenStore.shared.token != nil else {
            tempMessage.status = "failed"
            errorMessage = "未登录，无法加密并发送语音消息"
            save(modelContext)
            return
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            guard let peerId = peerUserId(for: chat) else {
                throw APIClientError.server("缺少对方用户 ID，无法加密并发送语音消息")
            }
            let voiceData = try Data(contentsOf: recording.fileURL)
            let encrypted = try await E2EEManager.shared.encryptMediaPayload(
                voiceData,
                peerId: peerId,
                originalType: "voice",
                fileName: recording.fileURL.lastPathComponent,
                mimeType: "audio/mp4",
                duration: recording.duration,
                waveform: recording.waveform
            )
            let remoteMessage = try await APIClient.shared.sendMultipartMessage(
                chatId: chat.chatId,
                type: "voice",
                encryptedEnvelope: encrypted.envelopeString,
                fileData: encrypted.encryptedData,
                fileName: encrypted.encryptedFileName,
                mimeType: "application/octet-stream",
                duration: recording.duration,
                waveform: recording.waveform
            )
            let localVoiceURL = tempMessage.voiceURL
            let currentUserId = tempMessage.senderId
            let cached = try? await EncryptedMediaStore.shared.saveOutgoing(
                owner: currentUserId, messageID: remoteMessage.id, metadata: encrypted.metadata,
                remoteURL: remoteMessage.extra?.voiceUrl ?? remoteMessage.extra?.mediaUrl, plaintext: voiceData
            )
            guard currentUserId == UserDefaults.standard.string(forKey: "current_user_id") else { return }
            apply(remoteMessage, to: tempMessage, currentUserId: currentUserId)
            tempMessage.type = "voice"
            tempMessage.content = "[语音消息]"
            tempMessage.voiceURL = cached?.absoluteString ?? localVoiceURL
            tempMessage.mediaURL = tempMessage.voiceURL
            tempMessage.voiceDuration = recording.duration
            tempMessage.voiceWaveform = recording.waveform
            tempMessage.fileName = encrypted.metadata.fileName
            tempMessage.mimeType = encrypted.metadata.mimeType
            tempMessage.fileSize = voiceData.count
            chat.lastMessage = previewText(for: tempMessage)
            chat.updatedAt = tempMessage.createdAt
            save(modelContext)
        } catch {
            tempMessage.status = "failed"
            errorMessage = error.localizedDescription
            save(modelContext)
        }
    }

    func sendMediaMessage(
        data: Data,
        fileName: String,
        mimeType: String,
        type: String,
        in chat: Chat,
        modelContext: ModelContext
    ) async {
        guard chat.type != "group" else {
            errorMessage = groupEncryptionUnavailableMessage
            return
        }
        let tempId = UUID().uuidString
        guard !AIConversation.matches(chat.chatId) else { errorMessage = "imim AI 目前仅支持文字消息"; return }
        let placeholder = type == "image" ? "[图片]" : type == "video" ? "[视频]" : fileName
        let localURL = persistLocalMedia(data: data, fileName: fileName)
        let tempMessage = Message(
            messageId: tempId,
            chatId: chat.chatId,
            senderId: UserDefaults.standard.string(forKey: "current_user_id") ?? "me",
            content: placeholder,
            type: type,
            mediaURL: localURL?.absoluteString,
            fileName: fileName,
            fileSize: data.count,
            mimeType: mimeType,
            status: "sending",
            createdAt: Date(),
            isOutgoing: true,
            burnAfterRead: chat.vanishMode ? chat.vanishSeconds : nil,
            forwardRestricted: chat.restrictForwarding,
            chat: nil
        )

        chat.messages.append(tempMessage)
        chat.lastMessage = placeholder
        chat.updatedAt = tempMessage.createdAt
        isShowingAttachmentPanel = false
        save(modelContext)

        guard AuthTokenStore.shared.token != nil else {
            tempMessage.status = "failed"
            errorMessage = "未登录，无法加密并发送媒体消息"
            save(modelContext)
            return
        }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            guard let peerId = peerUserId(for: chat) else {
                throw APIClientError.server("缺少对方用户 ID，无法加密并发送媒体消息")
            }
            let encrypted = try await E2EEManager.shared.encryptMediaPayload(
                data,
                peerId: peerId,
                originalType: type,
                fileName: fileName,
                mimeType: mimeType
            )
            let remoteMessage = try await APIClient.shared.sendMultipartMessage(
                chatId: chat.chatId,
                type: type,
                encryptedEnvelope: encrypted.envelopeString,
                fileData: encrypted.encryptedData,
                fileName: encrypted.encryptedFileName,
                mimeType: "application/octet-stream"
            )
            let localMediaURL = tempMessage.mediaURL
            let currentUserId = tempMessage.senderId
            let cached = try? await EncryptedMediaStore.shared.saveOutgoing(
                owner: currentUserId, messageID: remoteMessage.id, metadata: encrypted.metadata,
                remoteURL: remoteMessage.extra?.mediaUrl, plaintext: data
            )
            guard currentUserId == UserDefaults.standard.string(forKey: "current_user_id") else { return }
            apply(remoteMessage, to: tempMessage, currentUserId: currentUserId)
            tempMessage.type = type
            tempMessage.content = placeholder
            tempMessage.mediaURL = cached?.absoluteString ?? localMediaURL
            tempMessage.fileName = fileName
            tempMessage.fileSize = data.count
            tempMessage.mimeType = mimeType
            chat.lastMessage = previewText(for: tempMessage)
            chat.updatedAt = tempMessage.createdAt
            save(modelContext)
        } catch {
            tempMessage.status = "failed"
            errorMessage = error.localizedDescription
            save(modelContext)
        }
    }

    func appendIncomingMessage(_ message: Message, to chat: Chat, modelContext: ModelContext) {
        guard !chat.messages.contains(where: { $0.messageId == message.messageId }) else { return }
        message.isOutgoing = false
        message.status = "received"
        message.chat = nil
        chat.messages.append(message)
        chat.lastMessage = message.content
        chat.updatedAt = message.createdAt
        chat.unreadCount = 0
        // SwiftData autosaves this relationship. A synchronous save here
        // serializes the full chat graph on every WebSocket delivery and was
        // the source of visible receive-side jank.
    }

    func handleSocketMessage(_ message: Message, isAck: Bool, in chat: Chat, modelContext: ModelContext) {
        if isAck {
            if let existing = chat.messages.first(where: { $0.messageId == message.messageId || ($0.status == "sending" && $0.content == message.content) }) {
                existing.messageId = message.messageId
                existing.senderId = message.senderId
                if message.type != "encrypted", message.content != "🔒 加密消息" {
                    existing.content = message.content
                    existing.type = message.type
                }
                // HTTP/WebSocket ACKs contain ciphertext URLs. Keep the local
                // playable file and original metadata of encrypted attachments.
                let keepAttachment = ["voice", "image", "video", "file"].contains(existing.type)
                if !keepAttachment {
                    existing.voiceURL = message.voiceURL
                    existing.voiceDuration = message.voiceDuration
                    existing.voiceWaveform = message.voiceWaveform
                    existing.mediaURL = message.mediaURL
                    existing.fileName = message.fileName
                    existing.fileSize = message.fileSize
                    existing.mimeType = message.mimeType
                }
                existing.stickerURL = message.stickerURL
                existing.stickerEmoji = message.stickerEmoji
                existing.stickerName = message.stickerName
                existing.stickerFormat = message.stickerFormat
                existing.stickerThumbURL = message.stickerThumbURL
                existing.stickerPackID = message.stickerPackID
                existing.status = MessageDeliveryState.merging(status: existing.status, readAt: existing.readAt, remoteStatus: "sent")
                existing.createdAt = message.createdAt
                existing.isOutgoing = true
                chat.lastMessage = previewText(for: existing)
                chat.updatedAt = message.createdAt
                save(modelContext)
            }
            return
        }

        appendIncomingMessage(message, to: chat, modelContext: modelContext)
    }

    func simulateIncomingMessage(in chat: Chat, modelContext: ModelContext) {
        let replies = ["收到，我看一下。", "这个可以，继续推进。", "😊", "我晚点回复你详细版本。"]
        let message = Message(
            messageId: UUID().uuidString,
            chatId: chat.chatId,
            senderId: "friend",
            content: replies.randomElement() ?? "收到",
            status: "received",
            createdAt: Date(),
            isOutgoing: false,
            chat: nil
        )
        appendIncomingMessage(message, to: chat, modelContext: modelContext)
    }

    func markAsRead(_ chat: Chat, modelContext: ModelContext) {
        if AIConversation.matches(chat.chatId) {
            chat.unreadCount = 0
            sortedMessages(for: chat).filter { !$0.isOutgoing }.forEach { $0.readAt = Date() }
            save(modelContext)
            return
        }
        chat.unreadCount = 0
        if chat.type == "group" {
            save(modelContext)
            return
        }
        // Call records are local metadata, not server message IDs/receipts.
        let unreadIncoming = chat.messages.filter { !$0.isOutgoing && $0.readAt == nil && $0.type != "call" }
        if ConversationPreferences.readReceiptsEnabled(for: chat.chatId), !unreadIncoming.isEmpty {
            SocketManager.shared.sendReadReceipt(
                chatId: chat.chatId,
                messageIds: unreadIncoming.map(\.messageId),
                to: peerUserId(for: chat)
            )
            let now = Date()
            unreadIncoming.forEach { $0.readAt = now }
        }
        save(modelContext)

        guard AuthTokenStore.shared.token != nil else { return }
        Task {
            do {
                try await APIClient.shared.markChatAsRead(chatId: chat.chatId)
                let now = Date()
                for message in chat.messages where !message.isOutgoing && message.burnAfterRead != nil && message.burnReadAt == nil {
                    message.readAt = now
                    message.burnReadAt = now
                    if let seconds = message.burnAfterRead {
                        message.burnExpireAt = now.addingTimeInterval(TimeInterval(seconds))
                    }
                }
                save(modelContext)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func recall(_ message: Message, in chat: Chat, modelContext: ModelContext) async {
        guard message.isOutgoing else { return }
        guard chat.type != "group" else {
            errorMessage = "当前 iOS 版本尚未接入 MLS 群消息撤回"
            return
        }

        if AuthTokenStore.shared.token != nil {
            do {
                try await APIClient.shared.recallMessage(chatId: chat.chatId, messageId: message.messageId)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        message.content = "消息已撤回"
        message.type = "text"
        message.voiceURL = nil
        message.mediaURL = nil
        message.status = "sent"
        if chat.lastMessage == previewText(for: message) || chat.updatedAt == message.createdAt {
            chat.lastMessage = "消息已撤回"
        }
        save(modelContext)
    }

    func retryMedia(_ message: Message, modelContext: ModelContext) async {
        guard let owner = UserDefaults.standard.string(forKey: "current_user_id"),
              let origin = URL(string: AppServer.origin) else { return }
        do {
            let local = try await EncryptedMediaStore.shared.localFile(owner: owner, messageID: message.messageId, origin: origin)
            guard owner == UserDefaults.standard.string(forKey: "current_user_id") else { return }
            message.mediaURL = local.absoluteString
            if message.type == "voice" { message.voiceURL = local.absoluteString }
            save(modelContext)
        } catch { errorMessage = error.localizedDescription }
    }

    private func merge(remoteMessages: [RemoteMessage], into chat: Chat) async {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
        var existingIds = Set(chat.messages.map(\.messageId))

        // The ratchet is order-sensitive. Always process newly fetched
        // ciphertext from oldest to newest, independent of API ordering.
        for remoteMessage in remoteMessages.sorted(by: { $0.createdAt < $1.createdAt }) {
            if existingIds.contains(remoteMessage.id) {
                if let existing = chat.messages.first(where: { $0.messageId == remoteMessage.id }),
                   existing.isOutgoing, remoteMessage.senderId == currentUserId {
                    existing.status = MessageDeliveryState.merging(
                        status: existing.status, readAt: existing.readAt,
                        remoteStatus: remoteMessage.status ?? existing.status
                    )
                }
                if let existing = chat.messages.first(where: { $0.messageId == remoteMessage.id }),
                   ["image", "voice", "video", "file"].contains(existing.type),
                   let owner = currentUserId, let origin = URL(string: AppServer.origin),
                   let local = try? await EncryptedMediaStore.shared.localFile(owner: owner, messageID: existing.messageId, origin: origin),
                   owner == UserDefaults.standard.string(forKey: "current_user_id") {
                    existing.mediaURL = local.absoluteString
                    if existing.type == "voice" { existing.voiceURL = local.absoluteString }
                }
                // A failed historical ciphertext may reference an already
                // consumed PreKey. Retrying it on every refresh used to reset
                // the live session and made the next real-time message fail.
                continue
            }

            if let stored = IncomingMessagePersistence.shared.stored(remoteMessage.id, owner: currentUserId) {
                if !chat.messages.contains(where: { $0.messageId == stored.messageId }) {
                    chat.messages.append(stored)
                }
                existingIds.insert(remoteMessage.id)
                continue
            }
            guard IncomingMessagePersistence.shared.begin(remoteMessage.id, owner: currentUserId) else { continue }
            let localMessage = await remoteMessage.toLocalMessageResolvingEncryption(currentUserId: currentUserId)
            // Historical failures never initiate a reset of the live peer.
            // Recovery is an explicit user action, not a consequence of paging.
            let stored = IncomingMessagePersistence.shared.store(localMessage, owner: currentUserId, saveImmediately: false)
            if let stored, !chat.messages.contains(where: { $0.messageId == stored.messageId }) {
                chat.messages.append(stored)
            }
            existingIds.insert(remoteMessage.id)
        }

        if let last = chat.messages.max(by: { $0.createdAt < $1.createdAt }) {
            chat.lastMessage = previewText(for: last)
            chat.updatedAt = last.createdAt
        }
    }

    private func merge(groupMessages: [RemoteGroupMessage], into chat: Chat, currentUserId: String) async {
        var existingIds = Set(chat.messages.map(\.messageId))
        for remoteMessage in groupMessages {
            let stableMessageId = "\(chat.chatId):\(remoteMessage.seq)"
            if existingIds.contains(stableMessageId) {
                guard let existing = chat.messages.first(where: { $0.messageId == stableMessageId }),
                      existing.content.contains("等待密钥同步") else { continue }
                let resolved = await remoteMessage.toLocalMessageResolvingMLS(
                    currentUserId: currentUserId,
                    groupId: chat.chatId
                )
                if !resolved.content.contains("等待密钥同步") {
                    existing.content = resolved.content
                    existing.type = resolved.type
                }
                continue
            }
            let local = await remoteMessage.toLocalMessageResolvingMLS(
                currentUserId: currentUserId,
                groupId: chat.chatId
            )
            chat.messages.append(local)
            existingIds.insert(stableMessageId)
        }

        if let last = chat.messages.max(by: { $0.createdAt < $1.createdAt }) {
            chat.lastMessage = previewText(for: last)
            chat.updatedAt = last.createdAt
        }
    }

    private func sendGroupTextMessage(_ content: String, in chat: Chat, modelContext: ModelContext) async -> Bool {
        guard !isSending else { return false }
        guard let token = AuthTokenStore.shared.token else {
            errorMessage = "请先登录后再建立群聊加密密钥"
            return false
        }
        guard let currentUserId = UserDefaults.standard.string(forKey: "current_user_id"),
              !currentUserId.isEmpty else {
            errorMessage = "缺少当前用户 ID，无法建立群聊加密密钥"
            return false
        }

        isSending = true
        errorMessage = nil
        noticeMessage = nil
        sendingMessageStatus = "正在同步群密钥…"
        var hasOutgoingMessage = false
        defer { isSending = false; sendingMessageStatus = nil }

        do {
            let ready = try await MLSGroupManager.shared.prepareGroup(
                groupId: chat.chatId,
                userId: currentUserId,
                waitForWelcome: true
            )
            try Task.checkCancellation()
            guard AuthTokenStore.shared.token == token,
                  UserDefaults.standard.string(forKey: "current_user_id") == currentUserId else { throw CancellationError() }
            guard ready else { throw MLSGroupError.waitingForExistingDevice }

            sendingMessageStatus = "正在发送…"

            let encrypted = try await MLSGroupManager.shared.encrypt(
                content,
                groupId: chat.chatId,
                userId: currentUserId
            )
            try Task.checkCancellation()
            guard AuthTokenStore.shared.token == token,
                  UserDefaults.standard.string(forKey: "current_user_id") == currentUserId else { throw CancellationError() }
            guard let wireData = encrypted.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(MLSWireEnvelope.self, from: wireData) else {
                throw MLSGroupError.invalidKeyMaterial
            }

            let tempMessage = Message(
                messageId: UUID().uuidString,
                chatId: chat.chatId,
                senderId: currentUserId,
                content: content,
                type: "text",
                status: "sending",
                createdAt: Date(),
                isOutgoing: true,
                chat: nil
            )
            chat.messages.append(tempMessage)
            hasOutgoingMessage = true
            chat.lastMessage = content
            chat.updatedAt = tempMessage.createdAt
            let replyToId = replyingTo?.messageId
            replyingTo = nil
            isShowingAttachmentPanel = false

            do {
                let response = try await APIClient.shared.sendGroupMessage(
                    groupId: chat.chatId,
                    senderId: currentUserId,
                    senderName: UserDefaults.standard.string(forKey: "current_user_name"),
                    encryptedContent: encrypted,
                    replyToId: replyToId,
                    extra: [
                        "originalType": "text",
                        "mlsEncrypted": true,
                        "mlsEpoch": wire.epoch,
                    ],
                    notificationText: chat.vanishMode ? nil : content
                )
                tempMessage.messageId = response.messageId ?? "\(chat.chatId):\(response.seq)"
                tempMessage.createdAt = Date(milliseconds: response.timestamp)
                tempMessage.status = "sent"
                chat.updatedAt = tempMessage.createdAt
                save(modelContext)
            } catch {
                tempMessage.status = "failed"
                save(modelContext)
                throw error
            }
        } catch is CancellationError {
            // Navigation/account changes cancel UI work, not the user's draft.
        } catch {
            errorMessage = error.localizedDescription
        }
        return hasOutgoingMessage
    }

    private func save(_ modelContext: ModelContext) {
        // ModelContext is view-scoped. Do not retain it in a delayed Task:
        // SwiftData asserts if that task runs after the originating context has
        // crossed its executor/lifetime boundary.
        try? modelContext.save()
    }

    private func apply(_ remoteMessage: RemoteMessage, to localMessage: Message, currentUserId: String?) {
        localMessage.messageId = remoteMessage.id
        localMessage.senderId = remoteMessage.senderId
        if remoteMessage.msgType == "encrypted" {
            localMessage.type = remoteMessage.extra?.originalType
                ?? (localMessage.type == "voice" || localMessage.type == "image" || localMessage.type == "video" || localMessage.type == "file" || localMessage.type == "sticker" || localMessage.type == "gif" || localMessage.type == "meme" ? localMessage.type : "text")
            if localMessage.content.isEmpty || localMessage.content == remoteMessage.content {
                localMessage.content = localMessage.type == "sticker" ? (remoteMessage.extra?.emoji ?? "[加密贴纸]") : "🔒 加密消息"
            }
        } else {
            localMessage.type = remoteMessage.msgType ?? localMessage.type
            localMessage.content = remoteMessage.content
        }
        if let voiceUrl = remoteMessage.extra?.voiceUrl {
            localMessage.voiceURL = voiceUrl
        }
        if let duration = remoteMessage.extra?.duration {
            localMessage.voiceDuration = duration
        }
        if let waveform = remoteMessage.extra?.waveform, !waveform.isEmpty {
            localMessage.voiceWaveform = waveform
        }
        let remoteMediaURL = remoteMessage.extra?.mediaUrl
            ?? remoteMessage.extra?.imageUrl
            ?? remoteMessage.extra?.videoUrl
            ?? remoteMessage.extra?.fileUrl
            ?? remoteMessage.extra?.url
            ?? remoteMessage.extra?.thumbUrl
        if let remoteMediaURL {
            localMessage.mediaURL = remoteMediaURL
        }
        localMessage.stickerURL = remoteMessage.extra?.stickerUrl ?? remoteMessage.extra?.url ?? remoteMessage.extra?.thumbUrl
        localMessage.stickerEmoji = remoteMessage.extra?.resolvedStickerEmoji
        localMessage.stickerName = remoteMessage.extra?.resolvedStickerName
        localMessage.stickerFormat = remoteMessage.extra?.resolvedStickerFormat
        localMessage.burnAfterRead = remoteMessage.burnAfterRead
        localMessage.burnReadAt = remoteMessage.burnReadAt.map(Date.init(milliseconds:))
        localMessage.burnExpireAt = remoteMessage.burnExpireAt.map(Date.init(milliseconds:))
        localMessage.forwardRestricted = remoteMessage.forwardRestricted ?? false
        localMessage.stickerThumbURL = remoteMessage.extra?.thumbUrl
        localMessage.stickerPackID = remoteMessage.extra?.stickerPackId
        localMessage.fileName = remoteMessage.extra?.fileName
        localMessage.fileSize = remoteMessage.extra?.fileSize
        localMessage.mimeType = remoteMessage.extra?.mimeType
        localMessage.status = MessageDeliveryState.merging(
            status: localMessage.status, readAt: localMessage.readAt,
            remoteStatus: remoteMessage.status ?? "sent"
        )
        localMessage.createdAt = Date(milliseconds: remoteMessage.createdAt)
        localMessage.isOutgoing = remoteMessage.senderId == currentUserId
    }

    private func previewText(for message: Message) -> String {
        switch message.type {
        case "call": return CallHistoryEntry.decode(message)?.titleKey ?? "通话记录不可用"
        case "image": return "图片"
        case "sticker", "gif", "meme": return message.stickerEmoji ?? "贴纸"
        case "voice": return "语音"
        case "video": return "视频"
        case "file": return message.fileName ?? "文件"
        default:
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text == "[加密消息]" || text == "🔒 加密消息" ? "加密消息" : text
        }
    }

    private func peerUserId(for chat: Chat) -> String? {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
        if let currentUserId, let peer = chat.memberIds.first(where: { $0 != currentUserId }) {
            return peer
        }
        return chat.memberIds.first
    }

    private var groupEncryptionUnavailableMessage: String {
        "这台 iPhone 尚未建立该群的 MLS 密钥，已阻止明文或私聊协议发送"
    }

    private func persistLocalMedia(data: Data, fileName: String) -> URL? {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("IMIMOutgoingMedia", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }
}
