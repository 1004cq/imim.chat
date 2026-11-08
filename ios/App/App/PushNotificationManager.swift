import Foundation
import AudioToolbox
import Combine
import Intents
import SwiftData
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
    private var modelContext: ModelContext?
    private var pendingRealtimeNotifications: Set<String> = []
    private var realtimePreviews: [String: String] = [:]
    private var realtimeOwners: [String: String] = [:]
    private var notificationAvatarDownloads: [String: (id: UUID, url: URL, task: Task<Data?, Never>)] = [:]

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

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
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
        if payload.isMessage {
            // Background/terminated alerts belong to APNs + the NSE. When
            // running in the foreground, share the WS path and message dedupe.
            if UIApplication.shared.applicationState == .active {
                showRealtimeMessageBanner(chatId: payload.chatId, title: payload.title,
                    avatarURL: payload.senderAvatarURL, senderId: payload.senderId,
                    messageId: payload.messageId, encryptedPreviewFields: userInfo)
            }
            return
        }
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
            try await APIClient.shared.registerVoIPToken(
                token,
                env: currentAPNsEnvironment()
            )
            lastErrorMessage = nil
            print("[Push] VoIP token uploaded: env=\(currentAPNsEnvironment().rawValue)")
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
        if payload.isMessage {
            showRealtimeMessageBanner(chatId: payload.chatId, title: payload.title,
                avatarURL: payload.senderAvatarURL, senderId: payload.senderId,
                messageId: payload.messageId, encryptedPreviewFields: notification.request.content.userInfo)
            return
        }
        guard markMessageDisplayed(payload.messageId) else { return }
        guard NotificationRouter.shared.activeConversationId != payload.chatId else { return }
        postBanner(for: payload)
    }

    func foregroundPresentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        let payload = PushPayload(userInfo: notification.request.content.userInfo)
        if NotificationRouter.shared.activeConversationId == payload.chatId { return [] }
        if payload.isMessage {
            guard isDeliveryEnabled, !ConversationPreferences.isMuted(for: payload.chatId) else { return [] }
            if notification.request.trigger is UNPushNotificationTrigger {
                // The same message can arrive through APNs and WS. Enrich it
                // once, then present our local communication notification.
                showForegroundNotification(notification)
                return []
            }
        }
        return [.banner, .list, .sound, .badge]
    }

    func showRealtimeMessageBanner(
        chatId: String,
        title: String = "IMIM Chat",
        body: String = "你收到一条新消息",
        avatarURL: String? = nil,
        senderId: String = "",
        messageId: String? = nil,
        playSound: Bool = true,
        decryptedPreview: String? = nil,
        encryptedPreviewFields: [AnyHashable: Any] = [:]
    ) {
        guard UIApplication.shared.applicationState == .active,
              NotificationRouter.shared.activeConversationId != chatId,
              !ConversationPreferences.isMuted(for: chatId), isDeliveryEnabled,
              let owner = UserDefaults.standard.string(forKey: "current_user_id") else { return }
        let requestID = "realtime-\(messageId ?? UUID().uuidString)"
        let trustedPreview = decryptedPreview ?? {
            // APNs carries ciphertext only; this is device-local decryption.
            let value = NotificationPreview.notificationBody(fields: encryptedPreviewFields)
            return value == "新消息" ? nil : value
        }()
        if let trustedPreview, pendingRealtimeNotifications.contains(requestID) {
            realtimePreviews[requestID] = NotificationPreview.shortText(trustedPreview)
        }
        guard markMessageDisplayed(messageId) else { return }
        let profile = cachedSenderProfile(chatId: chatId, senderId: senderId,
                                          title: title, avatarURL: avatarURL)
        let canPresentSystemBanner = isDeliveryEnabled
            && (authorizationStatus == .authorized
                || authorizationStatus == .provisional
                || authorizationStatus == .ephemeral)

        guard canPresentSystemBanner else {
            postBanner(title: profile.name, body: foregroundPreview(trustedPreview), chatId: chatId, avatarURL: profile.avatarURL)
            if playSound { playMessageAlertFeedback() }
            return
        }

        // Local notifications do not run the Notification Service Extension.
        // Apply the incoming intent using device-local decrypted content.
        // The plaintext never goes into userInfo, the server or APNs.
        let content = UNMutableNotificationContent()
        content.title = profile.name
        content.body = foregroundPreview(trustedPreview)
        content.sound = playSound ? UNNotificationSound(
            named: UNNotificationSoundName("juntos-607-trimmed.caf")
        ) : nil
        content.categoryIdentifier = PushCategory.message.rawValue
        content.threadIdentifier = chatId
        content.userInfo = [
            "type": "message",
            "chatId": chatId,
            "messageId": messageId ?? UUID().uuidString,
            "senderId": senderId,
            "senderName": profile.name,
            "avatarUrl": profile.avatarURL ?? "",
            "message_type": "encrypted",
        ]

        if let trustedPreview { realtimePreviews[requestID] = NotificationPreview.shortText(trustedPreview) }
        realtimeOwners[requestID] = owner
        pendingRealtimeNotifications.insert(requestID)
        // Also bounds cache IO and intent donation, not just network download.
        // The set is MainActor-owned: timeout and late callbacks deliver once.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.finishRealtimeNotification(requestID, content: content)
        }
        Task { [weak self] in
            guard let self else { return }
            let resolved = await self.resolveSenderProfile(profile, chatId: chatId, senderId: senderId)
            guard self.pendingRealtimeNotifications.contains(requestID) else { return }
            content.title = resolved.name
            content.userInfo["senderName"] = resolved.name
            content.userInfo["avatarUrl"] = resolved.avatarURL ?? ""
            var image = await AvatarImageLoader.shared.cachedNotificationImage(
                userId: senderId.nilIfBlank, urlString: resolved.avatarURL)
            guard self.pendingRealtimeNotifications.contains(requestID) else { return }
            if image == nil, let url = AvatarImageLoader.remoteURL(from: resolved.avatarURL),
               let data = await self.notificationAvatarData(senderId: senderId, url: url), let decoded = UIImage(data: data),
               decoded.size.width <= 2_048, decoded.size.height <= 2_048 {
                image = decoded
            }
            guard self.pendingRealtimeNotifications.contains(requestID) else { return }
            guard let image, let imageData = image.pngData(), let senderID = senderId.nilIfBlank else {
                self.finishRealtimeNotification(requestID, content: content)
                return
            }
            let intent = self.incomingMessageIntent(content: content, senderId: senderID, imageData: imageData)
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            do {
                try await interaction.donate()
                guard self.pendingRealtimeNotifications.contains(requestID) else { return }
                self.finishRealtimeNotification(requestID, content: (try? content.updating(from: intent)) ?? content)
            } catch {
                self.finishRealtimeNotification(requestID, content: content)
            }
        }
    }

    private struct SenderProfile {
        var name: String
        var avatarURL: String?
        var needsLookup: Bool
    }

    private func cachedSenderProfile(chatId: String, senderId: String, title: String, avatarURL: String?) -> SenderProfile {
        let name = title.nilIfBlank ?? "新消息"
        var profile = SenderProfile(name: name, avatarURL: avatarURL?.nilIfBlank,
            needsLookup: ["新消息", "IMIM Chat", "imimchat"].contains(name))
        guard let modelContext, !senderId.isEmpty else { return profile }
        let users = FetchDescriptor<User>(predicate: #Predicate { $0.userId == senderId })
        if let user = try? modelContext.fetch(users).first {
            if profile.needsLookup { profile.name = user.nickname?.nilIfBlank ?? user.username }
            profile.avatarURL = profile.avatarURL ?? user.avatar
            profile.needsLookup = false
            return profile
        }
        let chats = FetchDescriptor<Chat>(predicate: #Predicate { $0.chatId == chatId })
        if let chat = try? modelContext.fetch(chats).first, chat.type == "private",
           chat.memberIds.contains(senderId) {
            if profile.needsLookup { profile.name = chat.name.nilIfBlank ?? "新消息" }
            profile.avatarURL = profile.avatarURL ?? chat.avatar
            profile.needsLookup = profile.name == "新消息"
        }
        return profile
    }

    private func resolveSenderProfile(_ profile: SenderProfile, chatId: String, senderId: String) async -> SenderProfile {
        guard profile.needsLookup, !senderId.isEmpty,
              let chats = try? await APIClient.shared.fetchChats(timeoutInterval: 1.5),
              let peer = chats.first(where: { $0.id == chatId })?.peer, peer.id == senderId else { return profile }
        return SenderProfile(name: peer.nickname?.nilIfBlank ?? peer.username,
                             avatarURL: profile.avatarURL ?? peer.avatar, needsLookup: false)
    }

    private func notificationAvatarData(senderId: String, url: URL) async -> Data? {
        let key = senderId.nilIfBlank ?? url.path
        if let current = notificationAvatarDownloads[key], current.url == url { return await current.task.value }
        let id = UUID()
        let task = Task { await Self.downloadNotificationAvatar(url) }
        notificationAvatarDownloads[key] = (id, url, task)
        let data = await task.value
        if notificationAvatarDownloads[key]?.id == id { notificationAvatarDownloads.removeValue(forKey: key) }
        return data
    }

    nonisolated private static func downloadNotificationAvatar(_ url: URL) async -> Data? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (fileURL, response) = try? await session.download(from: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.url?.scheme?.lowercased() == "https",
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= 1_024 * 1_024 else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    private func finishRealtimeNotification(_ requestID: String, content: UNNotificationContent) {
        guard pendingRealtimeNotifications.remove(requestID) != nil else { return }
        let preview = realtimePreviews.removeValue(forKey: requestID)
        let owner = realtimeOwners.removeValue(forKey: requestID)
        guard owner != nil, owner == UserDefaults.standard.string(forKey: "current_user_id") else { return }
        let deliveredContent = (content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        deliveredContent.body = foregroundPreview(preview)
        let payload = PushPayload(userInfo: content.userInfo)
        // If the phone locks during enrichment, still deliver the alert we
        // accepted in the foreground (its remote banner was already consumed).
        guard isDeliveryEnabled,
              !ConversationPreferences.isMuted(for: payload.chatId) else { return }
        if UIApplication.shared.applicationState == .active,
           NotificationRouter.shared.activeConversationId == payload.chatId { return }
        let request = UNNotificationRequest(identifier: requestID, content: deliveredContent, trigger: nil)
        let title = content.title
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.lastErrorMessage = error.localizedDescription
                self?.postBanner(title: title, body: self?.foregroundPreview(preview) ?? "新消息", chatId: payload.chatId,
                                 avatarURL: payload.senderAvatarURL)
            }
        }
    }

    private func foregroundPreview(_ text: String?) -> String {
        guard !UserDefaults.standard.bool(forKey: "privacy_hide_message_previews"),
              UserDefaults.standard.object(forKey: "notification_in_app_preview") == nil
                || UserDefaults.standard.bool(forKey: "notification_in_app_preview"),
              let text else { return "新消息" }
        return NotificationPreview.shortText(text)
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

    private func incomingMessageIntent(
        content: UNNotificationContent, senderId: String, imageData: Data
    ) -> INSendMessageIntent {
        let image = INImage(imageData: imageData)
        let sender = INPerson(
            personHandle: INPersonHandle(value: senderId, type: .unknown),
            nameComponents: nil,
            displayName: content.title,
            image: image,
            contactIdentifier: nil,
            customIdentifier: senderId
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: content.threadIdentifier,
            serviceName: "imim",
            sender: sender,
            attachments: nil
        )
        intent.setImage(image, forParameterNamed: \.sender)
        return intent
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
        // Release builds installed over USB can still be development-signed.
        // Exporting for TestFlight re-signs the same archive for production.
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        return APNsEnvironmentResolver.current
        #endif
    }
}

private enum APNsEnvironmentResolver {
    static let current: PushTokenEnvironment = {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return environment(from: profile)
    }()

    static func environment(from profile: Data?) -> PushTokenEnvironment {
        // Store-distributed apps may omit the embedded profile. Their tokens
        // belong to production. Never infer the gateway from DEBUG or a receipt.
        guard let profile,
              let start = profile.range(of: Data("<plist".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String else {
            return .production
        }
        return environment == "development" ? .sandbox : .production
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
        let customData = userInfo["data"] as? [String: Any]

        title = (userInfo["senderName"] as? String)?.nilIfBlank
            ?? (userInfo["sender_name"] as? String)?.nilIfBlank
            ?? (customData?["senderName"] as? String)?.nilIfBlank
            ?? (userInfo["caller_name"] as? String)?.nilIfBlank
            ?? (alert?["title"] as? String)?.nilIfBlank
            ?? "IMIM Chat"

        let type = userInfo["type"] as? String ?? customData?["type"] as? String ?? ""
        let hasSender = userInfo["senderId"] != nil || userInfo["sender_id"] != nil || customData?["senderId"] != nil
        let hasChat = userInfo["chatId"] != nil || userInfo["chat_id"] != nil || customData?["chatId"] != nil
        isMessage = type != "call_invite" && (
            ["message", "private_message", "group_message"].contains(type)
            || (userInfo["message_type"] as? String) == "encrypted"
            || hasSender && hasChat
        )
        body = isMessage
            ? "新消息"
            : userInfo["message"] as? String
                ?? alert?["body"] as? String
                ?? "你收到一条新消息"

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

        senderAvatarURL = (userInfo["avatarUrl"] as? String)?.nilIfBlank
            ?? (userInfo["sender_avatar"] as? String)?.nilIfBlank
            ?? (userInfo["avatar_url"] as? String)?.nilIfBlank
            ?? (customData?["avatarUrl"] as? String)?.nilIfBlank

        senderId = userInfo["senderId"] as? String
            ?? userInfo["sender_id"] as? String
            ?? customData?["senderId"] as? String
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
