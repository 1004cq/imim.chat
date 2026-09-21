import Foundation
import Security

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
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedAccount.count >= 3 else {
            errorMessage = "请输入有效的用户 ID、邮箱或手机号"
            return
        }

        guard normalizedPassword.count >= 6 else {
            errorMessage = "请输入至少 6 位密码"
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await APIClient.shared.login(account: normalizedAccount, password: normalizedPassword)
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
        let token = currentUser?.token ?? AuthTokenStore.shared.token
        PushNotificationManager.shared.unregisterCurrentDevice(authToken: token)
        SocketManager.shared.disconnect()
        if let token, !token.isEmpty {
            Task {
                try? await APIClient.shared.logout(authTokenOverride: token)
            }
        }
        currentUser = nil
        userDefaults.removeObject(forKey: userKey)
        userDefaults.removeObject(forKey: tokenKey)
        userDefaults.removeObject(forKey: "current_user_id")
        userDefaults.removeObject(forKey: "current_user_name")
        userDefaults.removeObject(forKey: "current_user_avatar")
        AuthTokenStore.shared.clear()
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

    private let service = "chat.imim.auth"
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
