import Foundation
import AudioToolbox
import Combine
import Intents
import UIKit
import UserNotifications

@MainActor
final class NotificationRouter: ObservableObject {
    static let shared = NotificationRouter()

    @Published private(set) var activeConversationId: String?
    @Published var targetConversationId: String?

    private init() {}

    func setActiveConversation(_ conversationId: String?) {
        activeConversationId = conversationId
    }

    func openConversation(_ conversationId: String) {
        guard !conversationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        targetConversationId = conversationId
    }
}

@MainActor
final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var apnsToken: String?
    @Published private(set) var voipToken: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var needsNotificationSettings = false

    private let tokenKey = "apns_device_token"
    private let uploadedTokenKey = "apns_uploaded_device_token"
    private let voipTokenKey = "voip_push_token"
    private let deliveryEnabledKey = "push_delivery_enabled"
    private var recentlyDisplayedMessageIDs: [String: Date] = [:]

    @Published private(set) var isDeliveryEnabled: Bool

    var isSystemDeliveryReady: Bool {
        let isAuthorized = authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
        let token = apnsToken ?? UserDefaults.standard.string(forKey: tokenKey)
        let uploadedToken = UserDefaults.standard.string(forKey: uploadedTokenKey)
        return isDeliveryEnabled && isAuthorized && !((token ?? "").isEmpty) && token == uploadedToken
    }

    private init() {
        apnsToken = UserDefaults.standard.string(forKey: tokenKey)
        voipToken = UserDefaults.standard.string(forKey: voipTokenKey)
        if UserDefaults.standard.object(forKey: deliveryEnabledKey) == nil {
            UserDefaults.standard.set(true, forKey: deliveryEnabledKey)
        }
        isDeliveryEnabled = UserDefaults.standard.bool(forKey: deliveryEnabledKey)
    }

    func configure(notificationDelegate: UNUserNotificationCenterDelegate) {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        configureCategories()
        refreshAuthorizationStatus(registerIfAuthorized: true)
    }

    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    self.lastErrorMessage = error.localizedDescription
                }

                self.refreshAuthorizationStatus()

                guard granted else {
                    self.needsNotificationSettings = true
                    self.lastErrorMessage = "通知未开启。请前往系统设置允许横幅、声音和角标通知。"
                    return
                }

                self.needsNotificationSettings = false
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func refreshAuthorizationStatus(registerIfAuthorized: Bool = false) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.authorizationStatus = settings.authorizationStatus
                self.needsNotificationSettings = settings.authorizationStatus == .denied
                if self.needsNotificationSettings {
                    self.lastErrorMessage = "通知已在系统设置中关闭。"
                }
                if registerIfAuthorized,
                   settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func ensureRegistrationAndUpload() {
        refreshAuthorizationStatus(registerIfAuthorized: true)
        updatePresence(.foreground, activeChatId: NotificationRouter.shared.activeConversationId)
        Task {
            await uploadCurrentTokenIfPossible()
            await uploadCurrentVoIPTokenIfPossible()
        }
    }

    func setDeliveryEnabled(_ enabled: Bool) {
        guard isDeliveryEnabled != enabled else { return }
        isDeliveryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: deliveryEnabledKey)

        if enabled {
            requestAuthorizationAndRegister()
            Task {
                await uploadCurrentTokenIfPossible()
            }
        } else {
            unregisterCurrentDevice()
        }
    }

    func handleAPNsToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsToken = token
        lastErrorMessage = nil
        needsNotificationSettings = false
        UserDefaults.standard.set(token, forKey: tokenKey)
        if UserDefaults.standard.string(forKey: uploadedTokenKey) != token {
            UserDefaults.standard.removeObject(forKey: uploadedTokenKey)
        }

        NotificationCenter.default.post(
            name: .cqimPushTokenDidUpdate,
            object: nil,
            userInfo: ["token": token]
        )

        if token.count != 64 {
            print("[Push] APNs token has unexpected length: \(token.count)")
        }
        // APNs tokens identify a device installation. Keep diagnostics useful
        // without writing the complete token to local logs in any build.
        print("[Push] APNs token updated: \(self.maskedToken(token)), length=\(token.count)")
        Task {
            await uploadCurrentTokenIfPossible()
        }
    }

    func handleRegistrationFailure(_ error: Error) {
        lastErrorMessage = error.localizedDescription
        print("[Push] APNs registration failed: \(error.localizedDescription)")
    }

    func handleVoIPToken(_ token: String) {
        guard !token.isEmpty else { return }
        voipToken = token
        UserDefaults.standard.set(token, forKey: voipTokenKey)
        Task {
            await uploadCurrentVoIPTokenIfPossible()
        }
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        let payload = PushPayload(userInfo: userInfo)
        donateIncomingMessageIntent(for: payload)
        postBanner(for: payload)
    }

    func handleNotificationResponse(_ response: UNNotificationResponse) {
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        NotificationRouter.shared.openConversation(payload.chatId)
        NotificationCenter.default.post(
            name: .cqimPushNotificationDidOpenChat,
            object: nil,
            userInfo: ["chatId": payload.chatId]
        )
    }

    func uploadCurrentTokenIfPossible() async {
        guard let token = apnsToken ?? UserDefaults.standard.string(forKey: tokenKey),
              isDeliveryEnabled,
              AuthTokenStore.shared.token?.isEmpty == false else {
            return
        }

        do {
            try await APIClient.shared.registerPushToken(
                token: token,
                env: currentAPNsEnvironment(),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
            UserDefaults.standard.set(token, forKey: uploadedTokenKey)
            lastErrorMessage = nil
            print("[Push] APNs token uploaded: \(self.maskedToken(token)), env=\(currentAPNsEnvironment().rawValue)")
        } catch {
            UserDefaults.standard.removeObject(forKey: uploadedTokenKey)
            lastErrorMessage = error.localizedDescription
            print("[Push] APNs token upload failed: \(error.localizedDescription)")
        }
    }

    func uploadCurrentVoIPTokenIfPossible() async {
        guard let token = voipToken ?? UserDefaults.standard.string(forKey: voipTokenKey),
              AuthTokenStore.shared.token?.isEmpty == false else {
            return
        }

        do {
            try await APIClient.shared.registerVoIPToken(token)
            lastErrorMessage = nil
            print("[Push] VoIP token uploaded")
        } catch {
            lastErrorMessage = error.localizedDescription
            print("[Push] VoIP token upload failed: \(error.localizedDescription)")
        }
    }

    func unregisterCurrentDevice(authToken: String? = nil) {
        guard let token = apnsToken
            ?? UserDefaults.standard.string(forKey: uploadedTokenKey)
            ?? UserDefaults.standard.string(forKey: tokenKey) else {
            return
        }

        Task {
            do {
                try await APIClient.shared.deletePushToken(token: token, authToken: authToken)
                UserDefaults.standard.removeObject(forKey: uploadedTokenKey)
                print("[Push] APNs token deleted")
            } catch {
                print("[Push] APNs token delete failed: \(error.localizedDescription)")
            }
        }
    }

    func updatePresence(_ presence: AppPresence, activeChatId: String? = nil) {
        guard AuthTokenStore.shared.token?.isEmpty == false else { return }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "cqim.push-presence") {}
        Task {
            defer {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
            }
            do {
                try await APIClient.shared.updatePushPresence(
                    presence.rawValue,
                    activeChatId: presence == .foreground ? activeChatId : nil
                )
            } catch {
                print("[Push] presence upload failed: \(error.localizedDescription)")
            }
        }
    }

    func openNotificationSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    func showForegroundNotification(_ notification: UNNotification) {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        guard markMessageDisplayed(payload.messageId) else { return }
        guard NotificationRouter.shared.activeConversationId != payload.chatId else { return }
        postBanner(for: payload)
    }

    func showRealtimeMessageBanner(
        chatId: String,
        title: String = "IMIM Chat",
        body: String = "你收到一条新消息",
        avatarURL: String? = nil,
        messageId: String? = nil,
        playSound: Bool = true
    ) {
        guard markMessageDisplayed(messageId) else { return }
        let canPresentSystemBanner = isDeliveryEnabled
            && (authorizationStatus == .authorized
                || authorizationStatus == .provisional
                || authorizationStatus == .ephemeral)

        guard canPresentSystemBanner else {
            postBanner(title: title, body: body, chatId: chatId, avatarURL: avatarURL)
            if playSound { playMessageAlertFeedback() }
            return
        }

        // A foreground WebSocket message never reaches APNs while the server
        // considers this device online. Use a normal local alert so it follows
        // the same banner path as remote APNs, without exposing plaintext.
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = "加密消息"
        content.sound = .default
        content.categoryIdentifier = PushCategory.message.rawValue
        content.threadIdentifier = chatId
        content.userInfo = [
            "type": "message",
            "chatId": chatId,
            "messageId": messageId ?? UUID().uuidString,
            "sender_name": title,
            "sender_avatar": avatarURL ?? "",
            "message_type": "encrypted",
        ]
        let request = UNNotificationRequest(
            identifier: "realtime-\(messageId ?? UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastErrorMessage = error.localizedDescription
                self?.postBanner(title: title, body: body, chatId: chatId, avatarURL: avatarURL)
            }
        }
    }

    func scheduleLocalMessagePreview() {
        let content = UNMutableNotificationContent()
        content.title = "IMIM Chat"
        content.body = "这是一条本地模拟消息推送。"
        content.sound = UNNotificationSound(named: UNNotificationSoundName("juntos-607-trimmed.caf"))
        content.categoryIdentifier = PushCategory.message.rawValue
        content.userInfo = [
            "type": "message",
            "chatId": "local-preview",
            "sender_name": "系统通知"
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { @MainActor in
                    self.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func configureCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: PushAction.reply.rawValue,
            title: "回复",
            options: [],
            textInputButtonTitle: "发送",
            textInputPlaceholder: "输入回复"
        )
        let markReadAction = UNNotificationAction(
            identifier: PushAction.markAsRead.rawValue,
            title: "标为已读",
            options: []
        )
        let messageCategory = UNNotificationCategory(
            identifier: PushCategory.message.rawValue,
            actions: [replyAction, markReadAction],
            intentIdentifiers: ["INSendMessageIntent"],
            options: [.customDismissAction]
        )
        let callCategory = UNNotificationCategory(
            identifier: PushCategory.incomingCall.rawValue,
            actions: [],
            intentIdentifiers: ["INStartCallIntent"],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([messageCategory, callCategory])
    }

    private func postBanner(for payload: PushPayload) {
        postBanner(title: payload.title, body: payload.body, chatId: payload.chatId, avatarURL: payload.senderAvatarURL)
    }

    /// The Notification Service Extension supplies the avatar for lock-screen
    /// communication notifications. Donate the same message intent in the App
    /// when a remote notification is delivered while we are running.
    private func donateIncomingMessageIntent(for payload: PushPayload) {
        guard payload.isMessage, !payload.chatId.isEmpty else { return }
        let sender = INPerson(
            personHandle: INPersonHandle(value: payload.senderId.nilIfBlank ?? payload.title, type: .unknown),
            nameComponents: nil,
            displayName: payload.title,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: payload.senderId.nilIfBlank
        )
        let recipient = INPerson(
            personHandle: INPersonHandle(value: "me", type: .unknown),
            nameComponents: nil,
            displayName: "我",
            image: nil,
            contactIdentifier: nil,
            customIdentifier: "me"
        )
        let intent = INSendMessageIntent(
            recipients: [recipient],
            outgoingMessageType: .outgoingMessageText,
            content: "加密消息",
            speakableGroupName: nil,
            conversationIdentifier: payload.chatId,
            serviceName: "imimchat",
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
    }

    private func markMessageDisplayed(_ messageId: String?) -> Bool {
        guard let messageId, !messageId.isEmpty else { return true }
        let now = Date()
        recentlyDisplayedMessageIDs = recentlyDisplayedMessageIDs.filter { now.timeIntervalSince($0.value) < 60 }
        guard recentlyDisplayedMessageIDs[messageId] == nil else { return false }
        recentlyDisplayedMessageIDs[messageId] = now
        return true
    }

    private func maskedToken(_ token: String) -> String {
        guard token.count > 12 else { return token }
        return "\(token.prefix(6))...\(token.suffix(6))"
    }

    private func postBanner(title: String, body: String, chatId: String, avatarURL: String? = nil) {
        NotificationCenter.default.post(
            name: NSNotification.Name("CQIMShowBanner"),
            object: nil,
            userInfo: [
                "title": title,
                "body": body,
                "chatId": chatId,
                "avatarURL": avatarURL ?? ""
            ]
        )
    }

    private func playMessageAlertFeedback() {
        AudioServicesPlaySystemSound(1007)
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
    }

    private func currentAPNsEnvironment() -> PushTokenEnvironment {
        // The project uses separate debug/release entitlements, so this value
        // stays aligned with the provisioning profile that produced the token.
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

enum AppPresence: String {
    case foreground
    case background
    case offline
}

private enum PushCategory: String {
    case message = "MESSAGE"
    case incomingCall = "INCOMING_CALL"
}

private enum PushAction: String {
    case reply = "REPLY"
    case markAsRead = "MARK_AS_READ"
}

private struct PushPayload {
    let title: String
    let body: String
    let chatId: String
    let senderId: String
    let senderAvatarURL: String?
    let messageId: String?
    let isMessage: Bool

    init(userInfo: [AnyHashable: Any]) {
        let aps = userInfo["aps"] as? [String: Any]
        let alert = aps?["alert"] as? [String: Any]

        title = userInfo["sender_name"] as? String
            ?? userInfo["caller_name"] as? String
            ?? alert?["title"] as? String
            ?? "IMIM Chat"

        isMessage = (userInfo["type"] as? String) == "message"
            || (userInfo["message_type"] as? String) == "encrypted"
        body = isMessage
            ? "加密消息"
            : userInfo["message"] as? String
                ?? alert?["body"] as? String
                ?? "你收到一条新消息"

        let customData = userInfo["data"] as? [String: Any]
        chatId = userInfo["conversationId"] as? String
            ?? userInfo["conversation_id"] as? String
            ?? userInfo["chatId"] as? String
            ?? userInfo["chat_id"] as? String
            ?? customData?["conversationId"] as? String
            ?? customData?["conversation_id"] as? String
            ?? customData?["chatId"] as? String
            ?? customData?["chat_id"] as? String
            ?? "unknown"

        messageId = userInfo["messageId"] as? String
            ?? userInfo["message_id"] as? String
            ?? customData?["messageId"] as? String
            ?? customData?["message_id"] as? String

        senderAvatarURL = userInfo["sender_avatar"] as? String
            ?? userInfo["avatar_url"] as? String

        senderId = userInfo["senderId"] as? String
            ?? userInfo["sender_id"] as? String
            ?? ""
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Notification.Name {
    static let cqimPushTokenDidUpdate = Notification.Name("CQIMPushTokenDidUpdate")
    static let cqimPushNotificationDidOpenChat = Notification.Name("CQIMPushNotificationDidOpenChat")
}
