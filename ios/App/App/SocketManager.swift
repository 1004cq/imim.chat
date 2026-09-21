import Foundation
import Combine

class SocketManager: NSObject, ObservableObject {
    static let shared = SocketManager()

    @Published var isConnected = false
    @Published var lastReceivedMessage: Message?

    private var webSocketTask: URLSessionWebSocketTask?
    private var signalURL: URL {
        URL(string: "wss://wed.imim.chat/signal")!
    }

    private func makeSocketRequest() -> URLRequest? {
        guard let token = AuthTokenStore.shared.token, !token.isEmpty else { return nil }
        var request = URLRequest(url: signalURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    private var pingTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var isBackgrounded = false
    private var reconnectEnabled = false
    private var lastEncryptionResetRequest: [String: Date] = [:]

    private override init() {
        super.init()
    }

    func connect() {
        guard !isBackgrounded,
              AuthTokenStore.shared.token?.isEmpty == false else {
            return
        }

        reconnectEnabled = true
        closeConnection()
        guard let request = makeSocketRequest() else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
        startPinging()
    }

    func disconnect() {
        reconnectEnabled = false
        closeConnection()
    }

    /// A foreground WebSocket must not keep the user "online" after the app is backgrounded.
    /// The server can then deliver the normal APNs alert instead of skipping it as an online event.
    func enterBackground() {
        isBackgrounded = true
        reconnectEnabled = false
        closeConnection()
    }

    func enterForeground() {
        isBackgrounded = false
        guard AuthTokenStore.shared.token?.isEmpty == false else { return }
        connect()
    }

    func sendPrivateMessage(
        chatId: String,
        encryptedEnvelope: String,
        tempId: String,
        extra: [String: Any]? = nil
    ) {
        guard let validatedEnvelope = try? E2EEManager.shared.validateEnvelopeString(encryptedEnvelope) else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .cqimSocketErrorDidReceive,
                    object: E2EEError.invalidEnvelope.localizedDescription
                )
            }
            return
        }
        var messagePayload: [String: Any] = [
            "chatId": chatId,
            "content": validatedEnvelope,
            "msgType": "encrypted",
            "tempId": tempId
        ]
        if let extra {
            messagePayload["extra"] = extra
        }

        let payload: [String: Any] = [
            "type": "private_send",
            "payload": messagePayload
        ]
        sendJSON(payload)
    }

    func sendReadReceipt(chatId: String, messageIds: [String], to peerId: String?) {
        guard let peerId, !messageIds.isEmpty else { return }
        sendJSON([
            "type": "read_receipt",
            "to": peerId,
            "payload": [
                "chatId": chatId,
                "messageIds": messageIds
            ]
        ])
    }

    func sendRecall(messageId: String, to peerId: String?) {
        guard let peerId else { return }
        sendJSON([
            "type": "recall",
            "payload": [
                "toUserId": peerId,
                "messageId": messageId
            ]
        ])
    }

    /// A ratchet message cannot be decrypted after the receiver lost its local
    /// session. Ask the sender to discard its old ratchet so its next message
    /// is a new PreKey envelope instead of another unrecoverable message.
    func requestEncryptionSessionReset(with peerId: String) {
        let now = Date()
        if let previous = lastEncryptionResetRequest[peerId], now.timeIntervalSince(previous) < 30 {
            return
        }
        lastEncryptionResetRequest[peerId] = now
        sendJSON(["type": "e2ee_session_reset", "to": peerId])
    }

    func sendCallInvite(to peerId: String, roomId: String, callType: String, callerName: String, callerAvatar: String?, callId: String) {
        sendJSON([
            "type": "call_invite",
            "to": peerId,
            "payload": [
                "callType": callType,
                "roomId": roomId,
                "callerName": callerName,
                "callerAvatar": callerAvatar ?? "",
                "callId": callId
            ]
        ])
    }

    func sendCallAccept(to peerId: String) {
        sendJSON(["type": "call_accept", "to": peerId])
    }

    func sendCallReject(to peerId: String, callId: String? = nil) {
        var request: [String: Any] = ["type": "call_reject", "to": peerId]
        if let callId { request["payload"] = ["callId": callId] }
        sendJSON(request)
    }

    func sendCallEnd(to peerId: String, callId: String? = nil) {
        var request: [String: Any] = ["type": "call_end", "to": peerId]
        if let callId { request["payload"] = ["callId": callId] }
        sendJSON(request)
    }

    private func receiveMessage() {
        guard !isBackgrounded, let task = webSocketTask else { return }
        task.receive { [weak self] result in
            guard let self, self.webSocketTask === task, !self.isBackgrounded else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            case .failure(let error):
                print("WebSocket 接收失败: \(error)")
                DispatchQueue.main.async {
                    self.isConnected = false
                }
                self.scheduleReconnect()
            }
        }
    }

    private func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        if let envelope = try? JSONDecoder().decode(SocketEnvelope.self, from: data) {
            switch envelope.type {
            case "private_message":
                guard let payload = envelope.payload,
                      let remoteMessage = try? JSONDecoder().decode(RemoteMessage.self, from: payload) else { return }
                let currentUserId = UserDefaults.standard.string(forKey: "current_user_id")
                let isAck = envelope.payloadContainsAck
                Task { [weak self] in
                    guard let self else { return }
                    let senderName = remoteMessage.senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let notificationTitle = (senderName?.isEmpty == false ? senderName : nil) ?? "新消息"
                    let message: Message
                    if isAck {
                        message = remoteMessage.toLocalMessage(currentUserId: currentUserId)
                        if let tempId = remoteMessage.tempId {
                            message.messageId = tempId
                        }
                        message.status = "sent"
                    } else {
                        message = await remoteMessage.toLocalMessageResolvingEncryption(currentUserId: currentUserId)
                    }

                    await MainActor.run {
                        self.lastReceivedMessage = message
                        NotificationCenter.default.post(
                            name: .cqimPrivateMessageDidReceive,
                            object: message,
                            userInfo: ["ack": isAck]
                        )

                        if !isAck,
                           NotificationRouter.shared.activeConversationId != message.chatId,
                           !ConversationPreferences.isMuted(for: message.chatId) {
                            PushNotificationManager.shared.showRealtimeMessageBanner(
                                chatId: message.chatId,
                                title: notificationTitle,
                                body: remoteMessage.msgType == "encrypted" ? "你收到一条加密消息" : "你收到一条新消息",
                                avatarURL: remoteMessage.senderAvatar,
                                messageId: message.messageId
                            )
                        }
                    }
                }
            case "chat_privacy_updated":
                guard let payload = envelope.payload,
                      let privacy = try? JSONDecoder().decode(RemoteChatPrivacy.self, from: payload) else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cqimChatPrivacyDidReceive, object: privacy)
                }
            case "burn_read":
                guard let payload = envelope.payload,
                      let event = try? JSONDecoder().decode(BurnReadEvent.self, from: payload) else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cqimBurnReadDidReceive, object: event)
                }
            case "burn_delete":
                guard let payload = envelope.payload,
                      let event = try? JSONDecoder().decode(BurnDeleteEvent.self, from: payload) else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cqimBurnDeleteDidReceive, object: event)
                }
            case "read_receipt":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cqimReadReceiptDidReceive, object: nil)
                }
            case "recall_notify":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cqimMessageRecallDidReceive, object: envelope.payload)
                }
            case "e2ee_session_reset":
                guard let peerId = envelope.from, !peerId.isEmpty else { return }
                do {
                    try E2EEManager.shared.resetSession(with: peerId)
                    print("[E2EE] peer requested a new session")
                } catch {
                    print("[E2EE] unable to reset requested session: \(error.localizedDescription)")
                }
            case "call_invite":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .cqimCallInviteDidReceive,
                        object: nil,
                        userInfo: envelope.callUserInfo
                    )
                }
            case "call_accept":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo: envelope.callUserInfo)
                }
            case "call_reject":
                DispatchQueue.main.async {
                    if let from = envelope.callUserInfo["from"] as? String {
                        CallManager.shared.endCall(forPeerId: from, reason: .declinedElsewhere)
                    }
                    NotificationCenter.default.post(name: .cqimCallRejected, object: nil, userInfo: envelope.callUserInfo)
                }
            case "call_end":
                DispatchQueue.main.async {
                    if let from = envelope.callUserInfo["from"] as? String {
                        CallManager.shared.endCall(forPeerId: from, reason: .remoteEnded)
                    }
                    NotificationCenter.default.post(name: .cqimCallEnded, object: nil, userInfo: envelope.callUserInfo)
                }
            case "error":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .cqimSocketErrorDidReceive,
                        object: envelope.errorMessage
                    )
                }
            default:
                break
            }
            return
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let jsonString = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(jsonString)) { error in
            if let error = error {
                print("WebSocket 发送失败: \(error)")
            }
        }
    }

    private func startPinging() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if let error = error {
                    print("WebSocket Ping 失败: \(error)")
                    self?.isConnected = false
                }
            }
        }
    }

    private func closeConnection() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        DispatchQueue.main.async {
            self.isConnected = false
        }
    }

    private func scheduleReconnect() {
        guard reconnectEnabled, !isBackgrounded, reconnectWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.reconnectEnabled, !self.isBackgrounded else { return }
            print("尝试重新连接 WebSocket...")
            self.reconnectWorkItem = nil
            self.connect()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
    }
}

struct BurnReadEvent: Codable, Hashable {
    let chatId: String
    let messageId: String
    let readAt: Int64?
    let burnAfterRead: Int?
    let burnExpireAt: Int64?
}

struct BurnDeleteEvent: Codable, Hashable {
    let chatId: String
    let messageId: String
}

private struct SocketEnvelope: Decodable {
    let type: String
    let from: String?
    let to: String?
    let payload: Data?

    var payloadContainsAck: Bool {
        guard let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return false
        }
        return object["ack"] as? Bool == true
    }

    var callUserInfo: [String: Any] {
        var info: [String: Any] = [:]
        if let from { info["from"] = from }
        if let to { info["to"] = to }

        guard let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return info
        }

        for key in ["callType", "roomId", "callerName", "callerAvatar", "callId", "uuid", "isVideo"] {
            if let value = object[key] {
                info[key] = value
            }
        }
        if info["from"] == nil {
            for key in ["from", "fromUserId", "caller_id", "peerId"] {
                if let value = object[key] as? String, !value.isEmpty {
                    info["from"] = value
                    break
                }
            }
        }
        return info
    }

    var errorMessage: String {
        guard let payload,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return "WebSocket 请求失败"
        }
        return object["error"] as? String ?? object["message"] as? String ?? "WebSocket 请求失败"
    }

    enum CodingKeys: String, CodingKey {
        case type
        case from
        case fromUserId
        case callerId = "caller_id"
        case peerId
        case to
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        from = try container.decodeIfPresent(String.self, forKey: .from)
            ?? container.decodeIfPresent(String.self, forKey: .fromUserId)
            ?? container.decodeIfPresent(String.self, forKey: .callerId)
            ?? container.decodeIfPresent(String.self, forKey: .peerId)
        to = try container.decodeIfPresent(String.self, forKey: .to)
        if container.contains(.payload) {
            let raw = try container.decode(RawJSON.self, forKey: .payload)
            payload = raw.data
        } else {
            payload = nil
        }
    }
}

private struct RawJSON: Decodable {
    let data: Data

    init(from decoder: Decoder) throws {
        let value = try JSONSerialization.data(withJSONObject: AnyDecodable(from: decoder).value)
        data = value
    }
}

private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                value = NSNull()
            } else if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let int = try? container.decode(Int.self) {
                value = int
            } else if let double = try? container.decode(Double.self) {
                value = double
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let array = try? container.decode([AnyDecodable].self) {
                value = array.map(\.value)
            } else if let dictionary = try? container.decode([String: AnyDecodable].self) {
                value = dictionary.mapValues(\.value)
            } else {
                value = NSNull()
            }
        } else {
            value = NSNull()
        }
    }
}

extension Notification.Name {
    static let cqimPrivateMessageDidReceive = Notification.Name("CQIMPrivateMessageDidReceive")
    static let cqimReadReceiptDidReceive = Notification.Name("CQIMReadReceiptDidReceive")
    static let cqimMessageRecallDidReceive = Notification.Name("CQIMMessageRecallDidReceive")
    static let cqimCallInviteDidReceive = Notification.Name("CQIMCallInviteDidReceive")
    static let cqimCallAccepted = Notification.Name("CQIMCallAccepted")
    static let cqimCallRejected = Notification.Name("CQIMCallRejected")
    static let cqimCallEnded = Notification.Name("CQIMCallEnded")
    static let cqimCallAnsweredFromSystem = Notification.Name("CQIMCallAnsweredFromSystem")
    static let cqimSocketErrorDidReceive = Notification.Name("CQIMSocketErrorDidReceive")
    static let cqimChatPrivacyDidReceive = Notification.Name("CQIMChatPrivacyDidReceive")
    static let cqimBurnReadDidReceive = Notification.Name("CQIMBurnReadDidReceive")
    static let cqimBurnDeleteDidReceive = Notification.Name("CQIMBurnDeleteDidReceive")
}

extension SocketManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async {
            self.isConnected = true
            print("WebSocket 已连接")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async {
            self.isConnected = false
            print("WebSocket 已关闭")
        }
    }
}
