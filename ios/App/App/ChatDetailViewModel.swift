import Foundation
import SwiftData

@MainActor
final class ChatDetailViewModel: ObservableObject {
    @Published var isShowingAttachmentPanel = false
    @Published var isLoadingMessages = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var replyingTo: Message?
    @Published var voiceInputLockedUntil = Date.distantPast

    var canStartVoiceInput: Bool {
        Date() >= voiceInputLockedUntil && !isSending
    }

    func sortedMessages(for chat: Chat) -> [Message] {
        chat.messages.sorted { $0.createdAt < $1.createdAt }
    }

    func beginReply(to message: Message) {
        replyingTo = message
    }

    func cancelReply() {
        replyingTo = nil
    }

    func loadMessages(for chat: Chat, modelContext: ModelContext) async {
        guard AuthTokenStore.shared.token != nil else { return }

        isLoadingMessages = true
        errorMessage = nil
        noticeMessage = nil
        defer { isLoadingMessages = false }

        do {
            try await E2EEManager.shared.synchronizeCurrentUser()
            let remoteMessages = try await APIClient.shared.fetchMessages(chatId: chat.chatId)
            await merge(remoteMessages: remoteMessages, into: chat)
            chat.unreadCount = 0
            save(modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A retry for ciphertext that was encrypted to a discarded device key
    /// must create a new ratchet. Reloading the same ciphertext cannot recover
    /// a private key that is no longer on this device.
    func recoverEncryptionSession(for chat: Chat, modelContext: ModelContext) async {
        guard let peerId = peerUserId(for: chat) else {
            errorMessage = "缺少对方用户 ID，无法重建加密会话"
            return
        }

        errorMessage = nil
        noticeMessage = nil
        do {
            try E2EEManager.shared.resetSession(with: peerId)
            try await E2EEManager.shared.synchronizeCurrentUser(forceBundleRegistration: true)
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
            let remoteMessage = try await APIClient.shared.sendMessage(chatId: chat.chatId, encryptedEnvelope: encryptedEnvelope, replyToId: replyToId)
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

    func sendSticker(_ item: StickerItem, from pack: StickerPack?, in chat: Chat, modelContext: ModelContext) async {
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
                extra: extra
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
            let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
            apply(remoteMessage, to: tempMessage, currentUserId: currentUserId)
            tempMessage.type = "voice"
            tempMessage.content = "[语音消息]"
            tempMessage.voiceURL = tempMessage.voiceURL ?? localVoiceURL
            tempMessage.voiceDuration = tempMessage.voiceDuration ?? recording.duration
            if tempMessage.voiceWaveform.isEmpty {
                tempMessage.voiceWaveform = recording.waveform
            }
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
        let tempId = UUID().uuidString
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
            let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
            apply(remoteMessage, to: tempMessage, currentUserId: currentUserId)
            tempMessage.type = type
            tempMessage.content = placeholder
            tempMessage.mediaURL = tempMessage.mediaURL ?? localMediaURL
            tempMessage.fileName = tempMessage.fileName ?? fileName
            tempMessage.fileSize = tempMessage.fileSize ?? data.count
            tempMessage.mimeType = tempMessage.mimeType ?? mimeType
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
                existing.voiceURL = message.voiceURL
                existing.voiceDuration = message.voiceDuration
                existing.voiceWaveform = message.voiceWaveform
                existing.mediaURL = message.mediaURL
                existing.stickerURL = message.stickerURL
                existing.stickerEmoji = message.stickerEmoji
                existing.stickerName = message.stickerName
                existing.stickerFormat = message.stickerFormat
                existing.stickerThumbURL = message.stickerThumbURL
                existing.stickerPackID = message.stickerPackID
                existing.fileName = message.fileName
                existing.fileSize = message.fileSize
                existing.mimeType = message.mimeType
                existing.status = "sent"
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
        chat.unreadCount = 0
        let unreadIncoming = chat.messages.filter { !$0.isOutgoing && $0.readAt == nil }
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

    private func merge(remoteMessages: [RemoteMessage], into chat: Chat) async {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
        let existingIds = Set(chat.messages.map(\.messageId))

        for remoteMessage in remoteMessages {
            if existingIds.contains(remoteMessage.id) {
                guard remoteMessage.msgType == "encrypted",
                      remoteMessage.senderId != currentUserId,
                      let existingMessage = chat.messages.first(where: { $0.messageId == remoteMessage.id }),
                      existingMessage.content.contains("等待密钥同步") else {
                    continue
                }

                let resolvedMessage = await remoteMessage.toLocalMessageResolvingEncryption(currentUserId: currentUserId, chat: chat)
                guard !resolvedMessage.content.contains("等待密钥同步") else { continue }
                existingMessage.content = resolvedMessage.content
                existingMessage.type = resolvedMessage.type
                existingMessage.voiceURL = resolvedMessage.voiceURL
                existingMessage.voiceDuration = resolvedMessage.voiceDuration
                existingMessage.voiceWaveform = resolvedMessage.voiceWaveform
                existingMessage.mediaURL = resolvedMessage.mediaURL
                existingMessage.fileName = resolvedMessage.fileName
                existingMessage.mimeType = resolvedMessage.mimeType
                continue
            }

            let localMessage = await remoteMessage.toLocalMessageResolvingEncryption(currentUserId: currentUserId)
            chat.messages.append(localMessage)
        }

        if let last = chat.messages.max(by: { $0.createdAt < $1.createdAt }) {
            chat.lastMessage = previewText(for: last)
            chat.updatedAt = last.createdAt
        }
    }

    private func scheduleDeliveryUpdates(for message: Message, modelContext: ModelContext) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            message.status = "sent"
            self.save(modelContext)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            message.status = "read"
            message.readAt = Date()
            self.save(modelContext)
        }
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
        localMessage.status = remoteMessage.status ?? "sent"
        localMessage.createdAt = Date(milliseconds: remoteMessage.createdAt)
        localMessage.isOutgoing = remoteMessage.senderId == currentUserId
    }

    private func previewText(for message: Message) -> String {
        switch message.type {
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
