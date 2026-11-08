import Foundation
import SwiftData
import CryptoKit

/// Existing private-chat receipt payload; `peerID` comes from the authenticated
/// server envelope, never from a client-supplied field inside the payload.
struct MessageReadReceipt: Sendable {
    let chatID: String
    let messageIDs: Set<String>
    let peerID: String

    static func decode(_ data: Data, from peerID: String?) -> Self? {
        struct Payload: Decodable { let chatId: String; let messageIds: [String] }
        guard let peerID, !peerID.isEmpty, peerID.count <= 1024,
              let value = try? JSONDecoder().decode(Payload.self, from: data),
              !value.chatId.isEmpty, value.chatId.count <= 1024,
              !value.messageIds.isEmpty, value.messageIds.count <= 10_000,
              value.messageIds.allSatisfy({ !$0.isEmpty && $0.count <= 1024 }) else { return nil }
        return .init(chatID: value.chatId, messageIDs: Set(value.messageIds), peerID: peerID)
    }
}

enum MessageDeliveryState: Equatable {
    case sending, sent, read, failed

    static func resolve(status: String, readAt: Date?) -> Self {
        if status == "read" || readAt != nil { return .read }
        switch status {
        case "sending": return .sending
        case "failed": return .failed
        default: return .sent
        }
    }

    static func merging(status: String, readAt: Date?, remoteStatus: String) -> String {
        resolve(status: status, readAt: readAt) == .read ? "read" : remoteStatus
    }
}

/// A single SwiftData ingress for received private messages, independent of
/// which tab is visible. Never decrypt an already-consumed envelope again.
@MainActor
final class IncomingMessagePersistence {
    static let shared = IncomingMessagePersistence()
    private var context: ModelContext?
    private var inFlight = Set<String>()

    func configure(_ context: ModelContext) { self.context = context }

    /// Persist even when the chat is not open. Only the authenticated peer can
    /// acknowledge this owner's outgoing private messages in this exact chat.
    @discardableResult
    func applyReadReceipt(_ receipt: MessageReadReceipt, owner: String?, now: Date = Date()) -> Int {
        guard let owner, !owner.isEmpty,
              owner == UserDefaults.standard.string(forKey: "current_user_id"),
              receipt.peerID != owner, let context else { return 0 }
        let chatID = receipt.chatID
        var query = FetchDescriptor<Chat>(predicate: #Predicate { $0.chatId == chatID })
        query.fetchLimit = 1
        guard let chat = try? context.fetch(query).first,
              chat.type == "private", !chat.isBot, !chat.isOfficial,
              chat.memberIds.contains(owner), chat.memberIds.contains(receipt.peerID) else { return 0 }
        var changed = 0
        for message in chat.messages where message.chatId == chatID && message.isOutgoing
            && message.senderId == owner && message.type != "call"
            && receipt.messageIDs.contains(message.messageId) {
            if message.status != "read" || message.readAt == nil {
                message.status = "read"
                message.readAt = message.readAt ?? now
                changed += 1
            }
        }
        if changed > 0 { try? context.save() }
        return changed
    }

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

// MARK: - Local call history

/// Call metadata only, stored in the existing Message table. Never sent as a
/// plaintext chat message or used as evidence that an encrypted message arrived.
struct CallHistoryEntry: Codable, Equatable {
    enum Outcome: String, Codable { case completed, missed, cancelled, declined, failed }
    let ownerID: String
    let callID: String
    let peerID: String
    let mediaKind: String
    let isIncoming: Bool
    let startedAt: Date
    var connectedAt: Date?
    var endedAt: Date?
    var outcome: Outcome?

    var durationSeconds: Int {
        guard let connectedAt, let endedAt else { return 0 }
        return Int(max(0, min(endedAt.timeIntervalSince(connectedAt), 31_536_000)))
    }

    var formattedDuration: String {
        let seconds = durationSeconds
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var titleKey: String {
        let video = mediaKind == "video"
        switch outcome {
        case .completed:
            return isIncoming ? (video ? "视频来电" : "语音来电") : (video ? "视频通话" : "语音通话")
        case .missed: return video ? "未接视频来电" : "未接语音来电"
        case .cancelled: return video ? "视频通话已取消" : "语音通话已取消"
        case .declined:
            return isIncoming ? (video ? "已拒绝视频来电" : "已拒绝语音来电") : (video ? "视频通话被拒绝" : "语音通话被拒绝")
        case .failed, .none: return video ? "视频通话失败" : "语音通话失败"
        }
    }

    static func decode(_ message: Message) -> Self? {
        guard message.type == "call", let data = message.content.data(using: .utf8),
              let entry = try? JSONDecoder().decode(Self.self, from: data),
              entry.ownerID == UserDefaults.standard.string(forKey: "current_user_id"),
              entry.mediaKind == "audio" || entry.mediaKind == "video",
              entry.endedAt != nil, entry.outcome != nil else { return nil }
        return entry
    }
}

@MainActor
final class CallHistoryStore {
    static let shared = CallHistoryStore()
    struct Token: Hashable { fileprivate let owner: String; fileprivate let messageID: String }
    enum EndReason { case endedLocally, endedRemotely, declined, unanswered, failed }
    private struct Tracked {
        var entry: CallHistoryEntry
        let chatID: String?
    }
    private var calls: [Token: Tracked] = [:]
    private var context: ModelContext?
    private let owner: () -> String?
    private let now: () -> Date

    init(owner: @escaping () -> String? = { UserDefaults.standard.string(forKey: "current_user_id") },
         now: @escaping () -> Date = Date.init) {
        self.owner = owner
        self.now = now
    }

    func configure(_ context: ModelContext) {
        self.context = context
        flushPending()
    }

    @discardableResult
    func begin(callID: String, peerID: String, mediaKind: String, isIncoming: Bool, chatID: String? = nil) -> Token? {
        guard let ownerID = owner(), !ownerID.isEmpty, !callID.isEmpty, !peerID.isEmpty,
              peerID != ownerID, mediaKind == "audio" || mediaKind == "video" else { return nil }
        // Length-delimited encoding prevents ambiguous owner/call ID combinations.
        guard let identity = try? JSONEncoder().encode([ownerID, peerID, callID]) else { return nil }
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let token = Token(owner: ownerID, messageID: "local-call-" + digest)
        if calls[token] == nil {
            calls[token] = Tracked(entry: CallHistoryEntry(ownerID: ownerID, callID: callID,
                peerID: peerID, mediaKind: mediaKind, isIncoming: isIncoming, startedAt: now()), chatID: chatID)
        }
        return token
    }

    func connected(_ token: Token?) {
        guard let token, token.owner == owner(), var tracked = calls[token],
              tracked.entry.endedAt == nil, tracked.entry.connectedAt == nil else { return }
        tracked.entry.connectedAt = now()
        calls[token] = tracked
    }

    func finish(_ token: Token?, reason: EndReason) {
        guard let token, token.owner == owner(), var tracked = calls[token] else { return }
        guard tracked.entry.endedAt == nil else { persist(token, tracked); return }
        tracked.entry.endedAt = now()
        if reason == .failed {
            tracked.entry.outcome = .failed
        } else if tracked.entry.connectedAt != nil {
            tracked.entry.outcome = .completed
        } else {
            switch reason {
            case .declined: tracked.entry.outcome = .declined
            case .endedLocally: tracked.entry.outcome = tracked.entry.isIncoming ? .declined : .cancelled
            case .endedRemotely, .unanswered: tracked.entry.outcome = tracked.entry.isIncoming ? .missed : .cancelled
            case .failed: tracked.entry.outcome = .failed
            }
        }
        calls[token] = tracked
        persist(token, tracked)
    }

    private func resolveChat(for entry: CallHistoryEntry, hint: String?) throws -> Chat? {
        guard let context else { return nil }
        let chats = try context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.type == "private" }))
        let matches = chats.filter { $0.memberIds.contains(entry.ownerID) && $0.memberIds.contains(entry.peerID) }
        if let hint, let exact = matches.first(where: { $0.chatId == hint }) { return exact }
        // Never guess when two conversations claim the same participants.
        return matches.count == 1 ? matches.first : nil
    }

    private func persist(_ token: Token, _ tracked: Tracked) {
        guard token.owner == owner(), let context, tracked.entry.endedAt != nil else { return }
        do {
            let id = token.messageID
            var query = FetchDescriptor<Message>(predicate: #Predicate { $0.messageId == id })
            query.fetchLimit = 1
            if let existing = try context.fetch(query).first {
                // Retry an earlier failed save without inserting a second row.
                try context.save()
                if existing.type == "call" { calls.removeValue(forKey: token) }
                return
            }
            let chat = try resolveChat(for: tracked.entry, hint: tracked.chatID)
            let data = try JSONEncoder().encode(tracked.entry)
            let message = Message(messageId: id, chatId: chat?.chatId ?? "",
                senderId: tracked.entry.isIncoming ? tracked.entry.peerID : tracked.entry.ownerID,
                content: String(decoding: data, as: UTF8.self), type: "call", status: "local",
                createdAt: tracked.entry.startedAt, isOutgoing: !tracked.entry.isIncoming)
            context.insert(message)
            if let chat { attach(message, entry: tracked.entry, to: chat) }
            try context.save()
            calls.removeValue(forKey: token)
        } catch {
            // Retain pending metadata for the next flush; never print call IDs.
            print("[CallHistory] Unable to save local call record")
        }
    }

    private func attach(_ message: Message, entry: CallHistoryEntry, to chat: Chat) {
        message.chatId = chat.chatId
        if !chat.messages.contains(where: { $0.messageId == message.messageId }) { chat.messages.append(message) }
        if let ended = entry.endedAt, ended >= chat.updatedAt {
            chat.updatedAt = ended
            chat.lastMessage = entry.mediaKind == "video" ? "视频通话" : "语音通话"
        }
    }

    func flushPending() {
        // Account switches discard unfinished in-memory work from another owner.
        calls = calls.filter { $0.key.owner == owner() }
        for (token, tracked) in Array(calls) where tracked.entry.endedAt != nil { persist(token, tracked) }
        guard let context else { return }
        do {
            // A CallKit delivery may finish before the conversation list arrives.
            // Persist metadata first, then attach only after participant identities match.
            let orphans = try context.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.type == "call" && $0.chatId == "" }))
            for message in orphans {
                guard let data = message.content.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(CallHistoryEntry.self, from: data),
                      entry.ownerID == owner(), let chat = try resolveChat(for: entry, hint: nil) else { continue }
                attach(message, entry: entry, to: chat)
            }
            try context.save()
        } catch { print("[CallHistory] Unable to attach pending call records") }
    }
}

// MARK: - End local call history
