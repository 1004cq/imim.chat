import Foundation
import Security
import SwiftData

struct CurrentUser: Codable, Equatable {
    var id: String
    var account: String
    var nickname: String
    var avatar: String?
    var bio: String
    var token: String
}

@MainActor
final class AuthSession: ObservableObject {
    @Published private(set) var currentUser: CurrentUser?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var isDeletingAccount = false
    @Published var showAccountDeletionNotice = false
    @Published private(set) var accountDeletionNotice = ""

    private let userDefaults: UserDefaults
    private let userKey = "current_user"
    private let tokenKey = "auth_token"

    var isAuthenticated: Bool {
        AuthTokenStore.shared.token?.isEmpty == false
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        restoreSession()
    }

    func signIn(account: String, password: String) async {
        let normalizedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        // Passwords are opaque credentials. Do not trim or normalize them;
        // legacy accounts may legitimately contain leading/trailing spaces.
        let loginPassword = password

        guard !normalizedAccount.isEmpty else {
            errorMessage = "请输入有效的用户 ID、邮箱或手机号"
            return
        }

        guard !loginPassword.isEmpty else {
            errorMessage = "请输入密码"
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient.shared.login(account: normalizedAccount, password: loginPassword)
            completeAuthentication(with: response)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendSMSCode(phone: String, type: AuthCodeType) async -> Bool {
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedPhone.count >= 6 else {
            errorMessage = "请输入有效手机号"
            return false
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            _ = try await APIClient.shared.sendSMSCode(target: normalizedPhone, type: type)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func signInWithSMS(phone: String, code: String) async {
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalizedPhone.isEmpty, normalizedPhone.count < 6 {
            errorMessage = "请输入有效手机号，或留空仅用用户名注册"
            return
        }

        if !normalizedPhone.isEmpty, normalizedCode.count < 4 {
            errorMessage = "请输入短信验证码，或留空手机号仅用用户名注册"
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient.shared.loginWithSMS(account: normalizedPhone, code: normalizedCode)
            completeAuthentication(with: response)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func register(username: String, password: String, nickname: String, phone: String, phoneCode: String) async {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = phoneCode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedUsername.count >= 3 else {
            errorMessage = "请输入至少 3 位用户名"
            return
        }

        guard normalizedPassword.count >= 6 else {
            errorMessage = "请输入至少 6 位密码"
            return
        }

        guard normalizedPhone.count >= 6 else {
            errorMessage = "请输入有效手机号"
            return
        }

        guard normalizedCode.count >= 4 else {
            errorMessage = "请输入验证码"
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient.shared.register(
                username: normalizedUsername,
                password: normalizedPassword,
                nickname: normalizedNickname,
                phone: normalizedPhone,
                phoneCode: normalizedCode
            )
            completeAuthentication(with: response)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateProfile(nickname: String, bio: String) async {
        guard var user = currentUser else { return }
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient.shared.updateProfile(nickname: trimmedNickname, bio: trimmedBio)
            user.nickname = response.profile?.nickname ?? response.profile?.name ?? response.user?.nickname ?? trimmedNickname
            user.bio = response.profile?.bio ?? response.user?.bio ?? trimmedBio
            persist(user)
            NotificationCenter.default.post(name: .cqimProfileDidChange, object: user)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateAvatar(path: String) {
        guard var user = currentUser else { return }
        user.avatar = path
        persist(user)
        NotificationCenter.default.post(name: .cqimAvatarDidChange, object: user)
    }

    func signOut() {
        PushNotificationManager.shared.unregisterCurrentDevice(authToken: currentUser?.token)
        SocketManager.shared.disconnect()
        currentUser = nil
        userDefaults.removeObject(forKey: userKey)
        userDefaults.removeObject(forKey: tokenKey)
        userDefaults.removeObject(forKey: "current_user_id")
        userDefaults.removeObject(forKey: "current_user_account")
        userDefaults.removeObject(forKey: "current_user_name")
        userDefaults.removeObject(forKey: "current_user_avatar")
        AuthTokenStore.shared.clear()
    }

    func deleteAccount(password: String, context: ModelContext) async throws {
        guard !isDeletingAccount, let user = currentUser, !password.isEmpty else {
            throw APIClientError.server("请先登录并输入当前账号密码")
        }
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        let response = try await APIClient.shared.deleteAccount(userID: user.id, password: password, token: user.token)
        guard response.success else { throw APIClientError.server("注销未完成，请重试") }
        // A switched account must never be signed out or have its data removed.
        guard currentUser?.id == user.id, currentUser?.token == user.token else { return }
        signOut()
        NotificationPreview.syncPreferences(userId: nil, hidden: true)
        var cleanupFailed = false
        do {
            let chats = try context.fetch(FetchDescriptor<Chat>()).filter { $0.memberIds.contains(user.id) }
            let chatIDs = Set(chats.map(\.chatId))
            let messages = try context.fetch(FetchDescriptor<Message>()).filter {
                chatIDs.contains($0.chatId) || $0.senderId == user.id
            }
            await EncryptedMediaStore.shared.remove(owner: user.id, messageIDs: messages.map(\.messageId))
            for message in messages { context.delete(message) }
            for chat in chats { context.delete(chat) }
            for profile in try context.fetch(FetchDescriptor<User>()) where profile.userId == user.id {
                context.delete(profile)
            }
            try context.save()
        } catch { cleanupFailed = true }
        do { try await E2EEManager.shared.removeAccountKeys(userId: user.id) }
        catch { cleanupFailed = true }
        do { try await MLSGroupManager.shared.removeAccount(userId: user.id) }
        catch { cleanupFailed = true }
        for service in [NotificationPreview.service] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: user.id]
            if service == NotificationPreview.service { query[kSecAttrAccessGroup as String] = NotificationPreview.group }
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { cleanupFailed = true }
        }
        AvatarStore.removeAccountAvatar(userId: user.id)
        accountDeletionNotice = "账号已永久注销，已退出登录。" +
            (response.mediaCleanupPending == true ? "媒体原文件正在后台清理。" : "") +
            (cleanupFailed ? "部分本机缓存清理失败，可在系统设置中删除 App 清理。" : "")
        showAccountDeletionNotice = true
    }

    private func restoreSession() {
        guard let data = userDefaults.data(forKey: userKey),
              var user = try? JSONDecoder().decode(CurrentUser.self, from: data),
              let token = AuthTokenStore.shared.token,
              !token.isEmpty else {
            return
        }
        user.token = token
        currentUser = user
        SocketManager.shared.connect()
        PushNotificationManager.shared.requestAuthorizationAndRegister()
        Task {
            await E2EEManager.shared.bootstrapForCurrentUser()
            await PushNotificationManager.shared.uploadCurrentTokenIfPossible()
            await PushNotificationManager.shared.uploadCurrentVoIPTokenIfPossible()
        }
    }

    private func completeAuthentication(with response: AuthLoginResponse) {
        let user = CurrentUser(
            id: response.user.id,
            account: response.user.username,
            nickname: response.user.nickname ?? response.user.username,
            avatar: response.user.avatar,
            bio: response.user.bio ?? "今天也在认真聊天。",
            token: response.token
        )
        persist(user)
        SocketManager.shared.connect()
        PushNotificationManager.shared.requestAuthorizationAndRegister()
        Task {
            await E2EEManager.shared.bootstrapForCurrentUser()
            await PushNotificationManager.shared.uploadCurrentTokenIfPossible()
            await PushNotificationManager.shared.uploadCurrentVoIPTokenIfPossible()
        }
    }

    private func persist(_ user: CurrentUser) {
        currentUser = user
        AuthTokenStore.shared.save(token: user.token)
        userDefaults.removeObject(forKey: tokenKey)
        userDefaults.set(user.id, forKey: "current_user_id")
        userDefaults.set(user.account, forKey: "current_user_account")
        userDefaults.set(user.nickname, forKey: "current_user_name")
        userDefaults.set(user.avatar, forKey: "current_user_avatar")
        var persistedUser = user
        persistedUser.token = ""
        if let data = try? JSONEncoder().encode(persistedUser) {
            userDefaults.set(data, forKey: userKey)
        }
    }
}

final class AuthTokenStore {
    static let shared = AuthTokenStore()

    // Scope authentication to the production API host so credentials from a
    // retired host cannot silently restore a session here.
    private let service = AppServer.authKeychainService
    private let account = "bearer-token"

    private init() {
        migrateLegacyUserDefaultsTokenIfNeeded()
    }

    var token: String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    func save(token: String) {
        guard let data = token.data(using: .utf8), !token.isEmpty else { return }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery()
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func migrateLegacyUserDefaultsTokenIfNeeded() {
        guard token == nil,
              let legacyToken = UserDefaults.standard.string(forKey: "auth_token"),
              !legacyToken.isEmpty else {
            return
        }
        save(token: legacyToken)
        UserDefaults.standard.removeObject(forKey: "auth_token")
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

extension Notification.Name {
    static let cqimAvatarDidChange = Notification.Name("CQIMAvatarDidChange")
    static let cqimProfileDidChange = Notification.Name("CQIMProfileDidChange")
}
