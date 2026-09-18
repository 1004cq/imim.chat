import Foundation
import SwiftData
import SwiftUI

@Model
final class User: Codable {
    var userId: String
    var username: String
    var email: String?
    var phone: String?
    var avatar: String?
    var nickname: String?
    var bio: String
    var token: String?
    var createdAt: Date

    init(
        userId: String,
        username: String,
        email: String? = nil,
        phone: String? = nil,
        avatar: String? = nil,
        nickname: String? = nil,
        bio: String = "保持联系，保持真实。",
        token: String? = nil,
        createdAt: Date = Date()
    ) {
        self.userId = userId
        self.username = username
        self.email = email
        self.phone = phone
        self.avatar = avatar
        self.nickname = nickname
        self.bio = bio
        self.token = token
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case userId, username, email, phone, avatar, nickname, bio, token, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userId = try container.decode(String.self, forKey: .userId)
        username = try container.decode(String.self, forKey: .username)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        bio = try container.decodeIfPresent(String.self, forKey: .bio) ?? "保持联系，保持真实。"
        token = try container.decodeIfPresent(String.self, forKey: .token)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(email, forKey: .email)
        try container.encodeIfPresent(phone, forKey: .phone)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        try container.encodeIfPresent(nickname, forKey: .nickname)
        try container.encode(bio, forKey: .bio)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

@Model
final class Chat: Codable {
    var chatId: String
    var name: String
    var avatar: String?
    var type: String // "private" or "group"
    var unreadCount: Int
    var lastMessage: String
    var updatedAt: Date
    var isPinned: Bool = false
    var isMuted: Bool = false
    var isEncrypted: Bool = true
    var isOfficial: Bool = false
    var isBot: Bool = false
    var memberIds: [String] = []
    var vanishMode: Bool = false
    var vanishSeconds: Int?
    var restrictForwarding: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \Message.chat)
    var messages: [Message]

    init(
        chatId: String,
        name: String,
        avatar: String? = nil,
        type: String = "private",
        unreadCount: Int = 0,
        lastMessage: String = "",
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        isMuted: Bool = false,
        isEncrypted: Bool = true,
        isOfficial: Bool = false,
        isBot: Bool = false,
        memberIds: [String] = [],
        vanishMode: Bool = false,
        vanishSeconds: Int? = nil,
        restrictForwarding: Bool = false,
        messages: [Message] = []
    ) {
        self.chatId = chatId
        self.name = name
        self.avatar = avatar
        self.type = type
        self.unreadCount = unreadCount
        self.lastMessage = lastMessage
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.isEncrypted = isEncrypted
        self.isOfficial = isOfficial
        self.isBot = isBot
        self.memberIds = memberIds
        self.vanishMode = vanishMode
        self.vanishSeconds = vanishSeconds
        self.restrictForwarding = restrictForwarding
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case chatId, name, avatar, type, unreadCount, lastMessage, updatedAt
        case isPinned, isMuted, isEncrypted, isOfficial, isBot, memberIds, vanishMode, vanishSeconds, restrictForwarding, messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatId = try container.decode(String.self, forKey: .chatId)
        name = try container.decode(String.self, forKey: .name)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "private"
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage) ?? ""
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isEncrypted = try container.decodeIfPresent(Bool.self, forKey: .isEncrypted) ?? true
        isOfficial = try container.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
        isBot = try container.decodeIfPresent(Bool.self, forKey: .isBot) ?? false
        memberIds = try container.decodeIfPresent([String].self, forKey: .memberIds) ?? []
        vanishMode = try container.decodeIfPresent(Bool.self, forKey: .vanishMode) ?? false
        vanishSeconds = try container.decodeIfPresent(Int.self, forKey: .vanishSeconds)
        restrictForwarding = try container.decodeIfPresent(Bool.self, forKey: .restrictForwarding) ?? false
        messages = try container.decodeIfPresent([Message].self, forKey: .messages) ?? []
        messages.forEach { $0.chat = self }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chatId, forKey: .chatId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(avatar, forKey: .avatar)
        try container.encode(type, forKey: .type)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(lastMessage, forKey: .lastMessage)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isMuted, forKey: .isMuted)
        try container.encode(isEncrypted, forKey: .isEncrypted)
        try container.encode(isOfficial, forKey: .isOfficial)
        try container.encode(isBot, forKey: .isBot)
        try container.encode(memberIds, forKey: .memberIds)
        try container.encode(vanishMode, forKey: .vanishMode)
        try container.encodeIfPresent(vanishSeconds, forKey: .vanishSeconds)
        try container.encode(restrictForwarding, forKey: .restrictForwarding)
        try container.encode(messages, forKey: .messages)
    }
}

@Model
final class Message: Codable {
    var messageId: String
    var chatId: String
    var senderId: String
    var content: String
    var type: String // "text", "image", etc.
    var voiceURL: String?
    var voiceDuration: Double?
    var voiceWaveform: [Double]
    var mediaURL: String?
    var stickerURL: String?
    var stickerEmoji: String?
    var stickerName: String?
    var stickerFormat: String?
    var stickerThumbURL: String?
    var stickerPackID: String?
    var fileName: String?
    var fileSize: Int?
    var mimeType: String?
    var status: String // "sending", "sent", "failed", "received"
    var createdAt: Date
    var isOutgoing: Bool
    var readAt: Date?
    var burnAfterRead: Int?
    var burnReadAt: Date?
    var burnExpireAt: Date?
    var forwardRestricted: Bool = false
    var chat: Chat?

    init(
        messageId: String,
        chatId: String,
        senderId: String,
        content: String,
        type: String = "text",
        voiceURL: String? = nil,
        voiceDuration: Double? = nil,
        voiceWaveform: [Double] = [],
        mediaURL: String? = nil,
        stickerURL: String? = nil,
        stickerEmoji: String? = nil,
        stickerName: String? = nil,
        stickerFormat: String? = nil,
        stickerThumbURL: String? = nil,
        stickerPackID: String? = nil,
        fileName: String? = nil,
        fileSize: Int? = nil,
        mimeType: String? = nil,
        status: String = "sent",
        createdAt: Date = Date(),
        isOutgoing: Bool = true,
        readAt: Date? = nil,
        burnAfterRead: Int? = nil,
        burnReadAt: Date? = nil,
        burnExpireAt: Date? = nil,
        forwardRestricted: Bool = false,
        chat: Chat? = nil
    ) {
        self.messageId = messageId
        self.chatId = chatId
        self.senderId = senderId
        self.content = content
        self.type = type
        self.voiceURL = voiceURL
        self.voiceDuration = voiceDuration
        self.voiceWaveform = voiceWaveform
        self.mediaURL = mediaURL
        self.stickerURL = stickerURL
        self.stickerEmoji = stickerEmoji
        self.stickerName = stickerName
        self.stickerFormat = stickerFormat
        self.stickerThumbURL = stickerThumbURL
        self.stickerPackID = stickerPackID
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.status = status
        self.createdAt = createdAt
        self.isOutgoing = isOutgoing
        self.readAt = readAt
        self.burnAfterRead = burnAfterRead
        self.burnReadAt = burnReadAt
        self.burnExpireAt = burnExpireAt
        self.forwardRestricted = forwardRestricted
        self.chat = chat
    }

    enum CodingKeys: String, CodingKey {
        case messageId, chatId, senderId, content, type, voiceURL, voiceDuration, voiceWaveform
        case mediaURL, stickerURL, stickerEmoji, stickerName, stickerFormat, stickerThumbURL, stickerPackID
        case fileName, fileSize, mimeType
        case status, createdAt, isOutgoing, readAt, burnAfterRead, burnReadAt, burnExpireAt, forwardRestricted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decode(String.self, forKey: .messageId)
        chatId = try container.decode(String.self, forKey: .chatId)
        senderId = try container.decode(String.self, forKey: .senderId)
        content = try container.decode(String.self, forKey: .content)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "text"
        voiceURL = try container.decodeIfPresent(String.self, forKey: .voiceURL)
        voiceDuration = try container.decodeIfPresent(Double.self, forKey: .voiceDuration)
        voiceWaveform = try container.decodeIfPresent([Double].self, forKey: .voiceWaveform) ?? []
        mediaURL = try container.decodeIfPresent(String.self, forKey: .mediaURL)
        stickerURL = try container.decodeIfPresent(String.self, forKey: .stickerURL)
        stickerEmoji = try container.decodeIfPresent(String.self, forKey: .stickerEmoji)
        stickerName = try container.decodeIfPresent(String.self, forKey: .stickerName)
        stickerFormat = try container.decodeIfPresent(String.self, forKey: .stickerFormat)
        stickerThumbURL = try container.decodeIfPresent(String.self, forKey: .stickerThumbURL)
        stickerPackID = try container.decodeIfPresent(String.self, forKey: .stickerPackID)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "received"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isOutgoing = try container.decodeIfPresent(Bool.self, forKey: .isOutgoing) ?? false
        readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
        burnAfterRead = try container.decodeIfPresent(Int.self, forKey: .burnAfterRead)
        burnReadAt = try container.decodeIfPresent(Date.self, forKey: .burnReadAt)
        burnExpireAt = try container.decodeIfPresent(Date.self, forKey: .burnExpireAt)
        forwardRestricted = try container.decodeIfPresent(Bool.self, forKey: .forwardRestricted) ?? false
        chat = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(chatId, forKey: .chatId)
        try container.encode(senderId, forKey: .senderId)
        try container.encode(content, forKey: .content)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(voiceURL, forKey: .voiceURL)
        try container.encodeIfPresent(voiceDuration, forKey: .voiceDuration)
        try container.encode(voiceWaveform, forKey: .voiceWaveform)
        try container.encodeIfPresent(mediaURL, forKey: .mediaURL)
        try container.encodeIfPresent(stickerURL, forKey: .stickerURL)
        try container.encodeIfPresent(stickerEmoji, forKey: .stickerEmoji)
        try container.encodeIfPresent(stickerName, forKey: .stickerName)
        try container.encodeIfPresent(stickerFormat, forKey: .stickerFormat)
        try container.encodeIfPresent(stickerThumbURL, forKey: .stickerThumbURL)
        try container.encodeIfPresent(stickerPackID, forKey: .stickerPackID)
        try container.encodeIfPresent(fileName, forKey: .fileName)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isOutgoing, forKey: .isOutgoing)
        try container.encodeIfPresent(readAt, forKey: .readAt)
        try container.encodeIfPresent(burnAfterRead, forKey: .burnAfterRead)
        try container.encodeIfPresent(burnReadAt, forKey: .burnReadAt)
        try container.encodeIfPresent(burnExpireAt, forKey: .burnExpireAt)
        try container.encode(forwardRestricted, forKey: .forwardRestricted)
    }
}

struct APIResponse<T: Codable>: Codable {
    let code: Int
    let message: String
    let data: T?
}
