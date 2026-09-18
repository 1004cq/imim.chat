import Foundation

class APIClient {
    static let shared = APIClient()
    private let baseURL = "https://wed.imim.chat/api"
    private let requiredTRTCSDKAppID = 1600159677

    private init() {}

    func request<T: Codable>(
        _ endpoint: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        authTokenOverride: String? = nil,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url, cachePolicy: cachePolicy)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let token = authTokenOverride ?? AuthTokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIClientError.server(apiError.error ?? apiError.message ?? "请求失败")
            }
            throw APIClientError.server("请求失败，状态码 \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if data.isEmpty, T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try decoder.decode(T.self, from: data)
    }

    func login(account: String, password: String) async throws -> AuthLoginResponse {
        try await request(
            "/auth/login",
            method: "POST",
            body: [
                "account": account,
                "password": password,
                "loginType": "password"
            ]
        )
    }

    func sendSMSCode(target: String, type: AuthCodeType) async throws -> AuthCodeResponse {
        try await request(
            "/auth/send-code",
            method: "POST",
            body: [
                "target": target,
                "type": type.rawValue,
                "channel": "sms"
            ]
        )
    }

    func loginWithSMS(account: String, code: String) async throws -> AuthLoginResponse {
        try await request(
            "/auth/login",
            method: "POST",
            body: [
                "account": account,
                "code": code,
                "loginType": "sms"
            ]
        )
    }

    func register(username: String, password: String, nickname: String?, phone: String, phoneCode: String) async throws -> AuthLoginResponse {
        var body: [String: Any] = [
            "username": username,
            "password": password
        ]
        if let nickname, !nickname.isEmpty {
            body["nickname"] = nickname
        }
        if !phone.isEmpty {
            body["phone"] = phone
        }
        if !phoneCode.isEmpty {
            body["phoneCode"] = phoneCode
        }

        return try await request(
            "/auth/register",
            method: "POST",
            body: body
        )
    }

    func searchUsers(keyword: String) async throws -> [RemoteUser] {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw URLError(.badURL)
        }
        let response: UserSearchResponse = try await request("/users/search?q=\(encoded)")
        return response.users
    }

    func sendFriendRequest(to userId: String, message: String) async throws -> FriendRequestResult {
        try await request(
            "/friend/request",
            method: "POST",
            body: [
                "toId": userId,
                "message": message,
                "searchMethod": "id"
            ]
        )
    }

    func fetchFriends() async throws -> [RemoteFriend] {
        let response: FriendListResponse = try await request("/friend/list")
        return response.friends
    }

    func createChat(targetUserId: String) async throws -> RemoteChat {
        let response: ChatResponse = try await request(
            "/chat/create",
            method: "POST",
            body: ["targetUserId": targetUserId]
        )
        return response.chat
    }

    func fetchChats() async throws -> [RemoteChat] {
        let response: ChatListResponse = try await request("/chat/list")
        return response.chats
    }

    func updateChatPrivacy(
        chatId: String,
        vanishMode: Bool,
        vanishSeconds: Int? = nil,
        restrictForwarding: Bool
    ) async throws -> RemoteChatPrivacy {
        var body: [String: Any] = [
            "vanishMode": vanishMode,
            "restrictForwarding": restrictForwarding,
        ]
        if let vanishSeconds {
            body["vanishSeconds"] = vanishSeconds
        }
        let response: ChatPrivacyResponse = try await request(
            "/chat/\(chatId)/privacy",
            method: "PATCH",
            body: body
        )
        return response.chat
    }

    func createGroup(name: String, ownerId: String, memberIds: [String]) async throws -> GroupCreateResponse {
        try await request(
            "/group/create",
            method: "POST",
            body: [
                "name": name,
                "ownerId": ownerId,
                "memberIds": memberIds,
                "type": "normal",
                "maxMembers": 500,
                "isPublic": false
            ]
        )
    }

    func fetchMessages(chatId: String, before messageId: String? = nil, limit: Int = 50) async throws -> [RemoteMessage] {
        var endpoint = "/chat/\(chatId)/messages?limit=\(limit)"
        if let messageId, !messageId.isEmpty {
            endpoint += "&before=\(messageId)"
        }
        let response: MessageListResponse = try await request(endpoint)
        return response.messages
    }

    func registerE2EEBundle(userId: String, bundle: E2EELocalPreKeyBundle, preKeys: [E2EEPreKeyUpload]) async throws {
        let signedPreKey: [String: Any] = [
            "keyId": bundle.signedPreKeyId,
            "publicKey": bundle.signedPreKey,
            "signature": bundle.signedPreKeySignature
        ]
        let preKeysPayload = preKeys.map { ["keyId": $0.keyId, "publicKey": $0.publicKey] as [String: Any] }
        let _: EmptyResponse = try await request(
            "/crypto/register-bundle",
            method: "POST",
            body: [
                "userId": userId,
                "registrationId": bundle.registrationId,
                "identityKey": bundle.identityKey,
                "signedPreKey": signedPreKey,
                "preKeys": preKeysPayload
            ]
        )
    }

    func fetchE2EEBundle(userId: String) async throws -> E2EEPreKeyBundle {
        guard let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw URLError(.badURL)
        }
        let response: RemoteE2EEBundleResponse = try await request("/crypto/get-bundle?userId=\(encoded)")
        guard let signedPreKeyId = response.signedPreKey.keyId,
              let signedPreKeyPublic = response.signedPreKey.publicKey,
              let signedPreKeySignature = response.signedPreKey.signature else {
            throw E2EEError.invalidRemoteBundle
        }
        return E2EEPreKeyBundle(
            registrationId: response.registrationId,
            identityKey: response.identityKey,
            signedPreKeyId: signedPreKeyId,
            signedPreKey: signedPreKeyPublic,
            signedPreKeySignature: signedPreKeySignature,
            oneTimePreKeyId: response.preKey?.keyId,
            oneTimePreKey: response.preKey?.publicKey
        )
    }

    func fetchE2EEPreKeyCount(userId: String) async throws -> Int {
        guard let encoded = userId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw URLError(.badURL)
        }
        let response: E2EEPreKeyCountResponse = try await request("/crypto/prekey-count?userId=\(encoded)")
        return response.count
    }

    func replenishE2EEPreKeys(userId: String, preKeys: [E2EEPreKeyUpload]) async throws {
        let preKeysPayload = preKeys.map { ["keyId": $0.keyId, "publicKey": $0.publicKey] as [String: Any] }
        let _: EmptyResponse = try await request(
            "/crypto/replenish-prekeys",
            method: "POST",
            body: [
                "userId": userId,
                "preKeys": preKeysPayload
            ]
        )
    }

    func sendMessage(
        chatId: String,
        encryptedEnvelope: String,
        replyToId: String? = nil,
        extra: [String: Any]? = nil
    ) async throws -> RemoteMessage {
        let validatedEnvelope = try E2EEManager.shared.validateEnvelopeString(encryptedEnvelope)
        var body: [String: Any] = [
            "content": validatedEnvelope,
            "msgType": "encrypted"
        ]
        if let replyToId {
            body["replyToId"] = replyToId
        }
        if let extra {
            body["extra"] = extra
        }

        let response: MessageResponse = try await request(
            "/chat/\(chatId)/messages",
            method: "POST",
            body: body
        )
        return response.message
    }

    func fetchStickerPacks() async throws -> [StickerPack] {
        let response: StickerPackResponse = try await request("/stickers/packs?includeStickers=true")
        return response.packs
    }

    func sendMultipartMessage(
        chatId: String,
        type: String,
        encryptedEnvelope: String,
        fileData: Data? = nil,
        fileName: String? = nil,
        mimeType: String? = nil,
        duration: Double? = nil,
        waveform: [Double]? = nil,
        replyTo: String? = nil
    ) async throws -> RemoteMessage {
        let validatedEnvelope = try E2EEManager.shared.validateEnvelopeString(encryptedEnvelope)
        guard let url = URL(string: "\(baseURL)/chat/send") else {
            throw URLError(.badURL)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let token = AuthTokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.appendMultipartField("chatId", value: chatId, boundary: boundary)
        body.appendMultipartField("type", value: type, boundary: boundary)
        body.appendMultipartField("msgType", value: "encrypted", boundary: boundary)
        body.appendMultipartField("originalType", value: type, boundary: boundary)
        body.appendMultipartField("content", value: validatedEnvelope, boundary: boundary)
        if let duration {
            body.appendMultipartField("duration", value: "\(duration)", boundary: boundary)
        }
        if let waveform,
           let data = try? JSONSerialization.data(withJSONObject: waveform),
           let json = String(data: data, encoding: .utf8) {
            body.appendMultipartField("waveform", value: json, boundary: boundary)
        }
        if let replyTo {
            body.appendMultipartField("replyTo", value: replyTo, boundary: boundary)
        }
        if let fileData {
            body.appendMultipartFile(
                fieldName: "file",
                fileName: fileName ?? "upload",
                mimeType: mimeType ?? "application/octet-stream",
                data: fileData,
                boundary: boundary
            )
        }
        body.append("--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw APIClientError.server(apiError.error ?? apiError.message ?? "发送失败")
            }
            throw APIClientError.server("发送失败，状态码 \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MessageResponse.self, from: data).message
    }

    func markChatAsRead(chatId: String, messageIds: [String]? = nil) async throws {
        var body: [String: Any] = [:]
        if let messageIds, !messageIds.isEmpty {
            body["messageIds"] = messageIds
        }
        let _: EmptyResponse = try await request("/chat/\(chatId)/read", method: "POST", body: body)
    }

    func registerPushToken(token: String, env: PushTokenEnvironment, appVersion: String?) async throws {
        var body: [String: Any] = [
            "token": token,
            "platform": "ios",
            "env": env.rawValue,
            "bundleId": Bundle.main.bundleIdentifier ?? ""
        ]
        if let appVersion, !appVersion.isEmpty {
            body["appVersion"] = appVersion
        }
        // The authenticated bearer token is the user binding. Do not trust a
        // userId supplied by the client, which would allow token reassignment.
        do {
            let _: EmptyResponse = try await request("/device/push-token", method: "POST", body: body)
        } catch {
            // Existing production nodes still expose the compatibility route.
            let _: EmptyResponse = try await request("/apns/token", method: "POST", body: body)
        }
    }

    func registerVoIPToken(_ token: String) async throws {
        let _: EmptyResponse = try await request(
            "/apns/voip-token",
            method: "POST",
            body: ["voipToken": token]
        )
    }

    func deletePushToken(token: String, authToken: String? = nil) async throws {
        do {
            let _: EmptyResponse = try await request(
                "/device/push-token",
                method: "DELETE",
                body: ["token": token],
                authTokenOverride: authToken
            )
        } catch {
            let _: EmptyResponse = try await request(
                "/apns/token",
                method: "DELETE",
                body: ["token": token],
                authTokenOverride: authToken
            )
        }
    }

    func updatePushPresence(_ presence: String, activeChatId: String? = nil) async throws {
        var body: [String: Any] = ["presence": presence]
        if let activeChatId, !activeChatId.isEmpty {
            body["activeChatId"] = activeChatId
        }
        let _: EmptyResponse = try await request("/device/presence", method: "POST", body: body)
    }

    func recallMessage(chatId: String, messageId: String) async throws {
        let _: EmptyResponse = try await request("/chat/\(chatId)/recall/\(messageId)", method: "POST")
    }

    func updateProfile(nickname: String, bio: String) async throws -> ProfileUpdateResponse {
        try await request(
            "/profile",
            method: "PUT",
            body: [
                "name": nickname,
                "nickname": nickname,
                "bio": bio
            ]
        )
    }

    /// The Moments cover is a profile field, so it stays in sync with the web client.
    func updateMomentCover(backgroundURL: String) async throws {
        let _: ProfileUpdateResponse = try await request(
            "/profile",
            method: "PUT",
            body: ["backgroundUrl": backgroundURL]
        )
    }

    func fetchCurrentProfile() async throws -> ProfilePayload {
        let response: CurrentProfileResponse = try await request("/profile")
        return response.profile
    }

    func uploadVoice(fileURL: URL, mimeType: String = "audio/mp4") async throws -> VoiceUploadResponse {
        let data = try Data(contentsOf: fileURL)
        return try await request(
            "/voice/upload",
            method: "POST",
            body: [
                "audioBase64": data.base64EncodedString(),
                "mimeType": mimeType
            ]
        )
    }

    func fetchTRTCUserSig() async throws -> TRTCCredentials {
        // A UserSig is short-lived and bound to the configured SDKAppID. Never
        // reuse an HTTP cache entry created before a server-side configuration change.
        let requestID = UUID().uuidString
        let credentials: TRTCCredentials = try await request(
            "/trtc/usersig?requestId=\(requestID)",
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        guard credentials.sdkAppId == requiredTRTCSDKAppID,
              !credentials.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.userSig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIClientError.server(
                "TRTC 服务端 SDKAppID 配置错误（期望 \(requiredTRTCSDKAppID)，实际 \(credentials.sdkAppId)）"
            )
        }
        return credentials
    }

    func fetchMomentsFeed(cursor: String? = nil, limit: Int = 20) async throws -> MomentFeedResponse {
        var endpoint = "/moments/feed?limit=\(limit)"
        if let cursor, !cursor.isEmpty,
           let encoded = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            endpoint += "&cursor=\(encoded)"
        }
        return try await request(endpoint)
    }

    func toggleMomentLike(momentId: String) async throws -> MomentLikeResponse {
        try await request("/moments/\(momentId)/like", method: "POST")
    }

    func createMoment(
        content: String,
        media: [MomentCreateMedia] = [],
        visibility: String = "public"
    ) async throws {
        let _: MomentMutationResponse = try await request(
            "/moments",
            method: "POST",
            body: [
                "content": content,
                "visibility": visibility,
                "media": media.map { ["type": $0.type, "url": $0.url] }
            ]
        )
    }

    func uploadMomentMedia(
        data: Data,
        fileName: String,
        mimeType: String,
        type: String
    ) async throws -> MomentCreateMedia {
        guard let url = URL(string: "\(baseURL)/media/upload-form") else {
            throw URLError(.badURL)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = AuthTokenStore.shared.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.appendMultipartField("mediaType", value: type, boundary: boundary)
        body.appendMultipartField("source", value: "moments", boundary: boundary)
        body.appendMultipartFile(
            fieldName: "file",
            fileName: fileName,
            mimeType: mimeType,
            data: data,
            boundary: boundary
        )
        body.append("--\(boundary)--\r\n")

        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: responseData) {
                throw APIClientError.server(apiError.error ?? apiError.message ?? "媒体上传失败")
            }
            throw APIClientError.server("媒体上传失败，状态码 \(httpResponse.statusCode)")
        }

        let upload = try JSONDecoder().decode(MomentMediaUploadResponse.self, from: responseData)
        guard upload.ok, !upload.url.isEmpty else {
            throw APIClientError.server("媒体上传失败")
        }
        return MomentCreateMedia(type: type, url: upload.url)
    }

    func createMomentComment(momentId: String, content: String) async throws {
        let _: MomentMutationResponse = try await request(
            "/moments/\(momentId)/comments",
            method: "POST",
            body: ["content": content]
        )
    }

    func uploadAvatar(
        imageData: Data,
        fileName: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        guard let url = URL(string: "\(baseURL)/upload/avatar") else {
            throw URLError(.badURL)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        if let token = AuthTokenStore.shared.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body = multipartBody(
            boundary: boundary,
            fieldName: "avatar",
            fileName: fileName,
            mimeType: "image/jpeg",
            data: imageData
        )

        await progress(0.15)
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: body)
        await progress(0.9)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        guard let avatarURL = parseAvatarURL(from: responseData) else {
            throw URLError(.cannotParseResponse)
        }

        await progress(1)
        return avatarURL
    }

    private func multipartBody(
        boundary: String,
        fieldName: String,
        fileName: String,
        mimeType: String,
        data: Data
    ) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func parseAvatarURL(from data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let urlString = object["url"] as? String {
            return URL(string: urlString)
        }

        if let dataObject = object["data"] as? [String: Any],
           let urlString = dataObject["url"] as? String ?? dataObject["avatar"] as? String ?? dataObject["avatarUrl"] as? String {
            return URL(string: urlString)
        }

        return nil
    }
}

enum PushTokenEnvironment: String {
    case sandbox
    case production
}

enum APIClientError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message):
            return message
        }
    }
}

struct APIErrorResponse: Codable {
    let error: String?
    let message: String?
}

struct EmptyResponse: Codable {}

enum AuthCodeType: String {
    case login
    case register
}

struct AuthCodeResponse: Codable {
    let success: Bool?
    let message: String?
}

struct ProfileUpdateResponse: Codable {
    let ok: Bool?
    let success: Bool?
    let profile: ProfilePayload?
    let user: AuthUserResponse?
}

struct ProfilePayload: Codable {
    let id: String?
    let name: String?
    let nickname: String?
    let avatar: String?
    let backgroundUrl: String?
    let bio: String?
}

struct CurrentProfileResponse: Codable {
    let profile: ProfilePayload
}

struct AuthLoginResponse: Codable {
    let success: Bool
    let token: String
    let user: AuthUserResponse
}

struct AuthUserResponse: Codable {
    let id: String
    let username: String
    let nickname: String?
    let phone: String?
    let email: String?
    let avatar: String?
    let bio: String?
}

struct RemoteUser: Codable, Identifiable, Hashable {
    let id: String
    let username: String
    let nickname: String?
    let avatar: String?
    let bio: String?
}

struct UserSearchResponse: Codable {
    let users: [RemoteUser]
}

struct FriendRequestResult: Codable {
    let success: Bool
    let message: String?
    let autoAccepted: Bool?
    let request: RemoteFriendRequest?
}

struct RemoteFriendRequest: Codable {
    let id: String
    let fromId: String
    let toId: String
    let message: String?
    let status: String
    let searchMethod: String?
    let createdAt: Int64?
}

struct FriendListResponse: Codable {
    let friends: [RemoteFriend]
}

struct RemoteFriend: Codable, Identifiable, Hashable {
    let id: String
    let uniqueId: String?
    let name: String
    let avatar: String?
    let bio: String?
    let status: String?
    let letter: String?
    let online: Bool?
    let deviceLabel: String?
    let lastSeen: Int64?
    let phone: String?
    let email: String?
}

struct ChatListResponse: Codable {
    let chats: [RemoteChat]
}

struct ChatResponse: Codable {
    let chat: RemoteChat
}

struct GroupCreateResponse: Codable {
    let ok: Bool?
    let groupId: String
    let dialogId: String?
}

struct RemoteChat: Codable, Identifiable, Hashable {
    let id: String
    let participantA: String
    let participantB: String
    let lastMessage: String?
    let lastMessageAt: Int64?
    let createdAt: Int64
    let unreadCount: Int?
    let peer: RemoteUser?
    let vanishMode: Bool?
    let vanishSeconds: Int?
    let restrictForwarding: Bool?
}

struct RemoteChatPrivacy: Codable, Hashable {
    let chatId: String
    let vanishMode: Bool
    let vanishSeconds: Int?
    let restrictForwarding: Bool
}

struct ChatPrivacyResponse: Codable {
    let chat: RemoteChatPrivacy
}

struct MessageListResponse: Codable {
    let messages: [RemoteMessage]
    let hasMore: Bool?
}

struct MessageResponse: Codable {
    let message: RemoteMessage
}

struct VoiceUploadResponse: Codable {
    let ok: Bool
    let voiceUrl: String
    let fileName: String?
}

struct TRTCUserSigEnvelope: Codable {
    let credentials: TRTCCredentials?
    let data: TRTCCredentials?
    let trtc: TRTCCredentials?
    let sdkAppId: Int?
    let sdkAppID: Int?
    let SDKAppID: Int?
    let userId: String?
    let userID: String?
    let userSig: String?
    let UserSig: String?
    let expireTime: Int?
}

struct MomentFeedResponse: Codable {
    let moments: [MomentFeedItem]
    let nextCursor: String?
    let hasMore: Bool?
}

struct MomentLikeResponse: Codable {
    let liked: Bool
    let likeCount: Int
}

struct MomentMutationResponse: Codable {
    let success: Bool?
}

struct MomentCreateMedia: Hashable {
    let type: String
    let url: String
}

private struct MomentMediaUploadResponse: Codable {
    let ok: Bool
    let url: String
}

struct MomentFeedItem: Codable, Identifiable, Hashable {
    let id: String
    let authorId: String
    let authorName: String
    let authorAvatar: String?
    let content: String
    let media: [MomentMediaItem]
    let location: String?
    let likeCount: Int
    let commentCount: Int
    let isLiked: Bool
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, authorId, authorName, authorAvatar, content, media, location
        case likeCount, commentCount, isLiked, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        authorId = try container.decodeIfPresent(String.self, forKey: .authorId) ?? ""
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        authorAvatar = try container.decodeIfPresent(String.self, forKey: .authorAvatar)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        media = try container.decodeIfPresent([MomentMediaItem].self, forKey: .media) ?? []
        location = try container.decodeIfPresent(String.self, forKey: .location)
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
        createdAt = try container.decodeFlexibleMillisecondsIfPresent(forKey: .createdAt) ?? 0
    }
}

struct MomentMediaItem: Codable, Hashable {
    let type: String
    let url: String
    let thumbUrl: String?
    let mediumUrl: String?
    let posterUrl: String?
    let videoUrl: String?
    let fileUrl: String?
    let mediaUrl: String?

    enum CodingKeys: String, CodingKey {
        case type, url, thumbUrl, mediumUrl, posterUrl, videoUrl, fileUrl, mediaUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "image"
        thumbUrl = try container.decodeIfPresent(String.self, forKey: .thumbUrl)
        mediumUrl = try container.decodeIfPresent(String.self, forKey: .mediumUrl)
        posterUrl = try container.decodeIfPresent(String.self, forKey: .posterUrl)
        videoUrl = try container.decodeIfPresent(String.self, forKey: .videoUrl)
        fileUrl = try container.decodeIfPresent(String.self, forKey: .fileUrl)
        mediaUrl = try container.decodeIfPresent(String.self, forKey: .mediaUrl)
        url = try container.decodeIfPresent(String.self, forKey: .url)
            ?? videoUrl
            ?? fileUrl
            ?? mediaUrl
            ?? thumbUrl
            ?? mediumUrl
            ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(thumbUrl, forKey: .thumbUrl)
        try container.encodeIfPresent(mediumUrl, forKey: .mediumUrl)
        try container.encodeIfPresent(posterUrl, forKey: .posterUrl)
        try container.encodeIfPresent(videoUrl, forKey: .videoUrl)
        try container.encodeIfPresent(fileUrl, forKey: .fileUrl)
        try container.encodeIfPresent(mediaUrl, forKey: .mediaUrl)
    }

    var playbackURLString: String? {
        videoUrl ?? mediaUrl ?? fileUrl ?? url.nilIfBlank
    }

    var previewURLString: String? {
        posterUrl ?? thumbUrl ?? mediumUrl ?? url.nilIfBlank
    }

    /// The server currently returns `video`, but older records can contain a MIME type.
    var isVideo: Bool {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedType == "video"
            || normalizedType.hasPrefix("video/")
            || normalizedType.contains("video")
            || playbackURLString?.lowercased().contains(".m3u8") == true
    }
}

struct RemoteMessageExtra: Codable, Hashable {
    let originalType: String?
    let voiceUrl: String?
    let duration: Double?
    let waveform: [Double]?
    let audioMimeType: String?
    let mediaUrl: String?
    let imageUrl: String?
    let videoUrl: String?
    let fileUrl: String?
    let thumbUrl: String?
    let stickerUrl: String?
    let stickerEmoji: String?
    let stickerSetName: String?
    let stickerFormat: String?
    let stickerId: String?
    let stickerPackId: String?
    let stickerPackName: String?
    let url: String?
    let emoji: String?
    let name: String?
    let format: String?
    let fileName: String?
    let fileSize: Int?
    let mimeType: String?

    var resolvedStickerEmoji: String? { stickerEmoji ?? emoji }
    var resolvedStickerName: String? { stickerSetName ?? stickerPackName ?? name }
    var resolvedStickerFormat: String? { stickerFormat ?? format }
}

struct RemoteMessage: Codable, Identifiable, Hashable {
    let id: String
    let chatId: String
    let senderId: String
    let msgType: String?
    let content: String
    let replyToId: String?
    let isRevoked: Bool?
    let status: String?
    let createdAt: Int64
    let tempId: String?
    let extra: RemoteMessageExtra?
    let senderName: String?
    let senderAvatar: String?
    let burnAfterRead: Int?
    let burnReadAt: Int64?
    let burnExpireAt: Int64?
    let forwardRestricted: Bool?
}

struct RemoteE2EESignedPreKey: Codable, Hashable {
    let keyId: Int?
    let publicKey: String?
    let signature: String?
}

struct RemoteE2EEPreKey: Codable, Hashable {
    let keyId: Int?
    let publicKey: String?
}

struct RemoteE2EEBundleResponse: Codable, Hashable {
    let registrationId: Int
    let identityKey: String
    let signedPreKey: RemoteE2EESignedPreKey
    let preKey: RemoteE2EEPreKey?
}

struct E2EEPreKeyCountResponse: Codable, Hashable {
    let count: Int
}

extension RemoteChat {
    func toLocalChat(currentUserId: String?) -> Chat {
        Chat(
            chatId: id,
            name: peer?.nickname ?? peer?.username ?? "未知用户",
            avatar: peer?.avatar,
            type: "private",
            unreadCount: unreadCount ?? 0,
            lastMessage: lastMessage ?? "",
            updatedAt: Date(milliseconds: lastMessageAt ?? createdAt),
            isEncrypted: true,
            memberIds: [participantA, participantB],
            vanishMode: vanishMode ?? false,
            vanishSeconds: vanishSeconds,
            restrictForwarding: restrictForwarding ?? false
        )
    }
}

extension RemoteMessage {
    func toLocalMessage(currentUserId: String?, chat: Chat? = nil) -> Message {
        let isEncrypted = msgType == "encrypted"
        let displayType = isEncrypted ? (extra?.originalType ?? "text") : (msgType ?? "text")
        let mediaURL = extra?.mediaUrl
            ?? extra?.imageUrl
            ?? extra?.videoUrl
            ?? extra?.fileUrl
            ?? extra?.url
            ?? extra?.thumbUrl
        let stickerURL = extra?.stickerUrl ?? extra?.url ?? extra?.thumbUrl
        let displayContent: String
        if isEncrypted {
            switch displayType {
            case "image": displayContent = "[加密图片]"
            case "voice": displayContent = "[加密语音]"
            case "video": displayContent = "[加密视频]"
            case "file": displayContent = "[加密文件]"
            case "sticker", "gif", "meme": displayContent = extra?.resolvedStickerEmoji ?? "[加密贴纸]"
            default: displayContent = "🔒 加密消息"
            }
        } else {
            displayContent = content
        }
        return Message(
            messageId: id,
            chatId: chatId,
            senderId: senderId,
            content: displayContent,
            type: displayType,
            voiceURL: extra?.voiceUrl,
            voiceDuration: extra?.duration,
            voiceWaveform: extra?.waveform ?? [],
            mediaURL: mediaURL,
            stickerURL: stickerURL,
            stickerEmoji: extra?.resolvedStickerEmoji,
            stickerName: extra?.resolvedStickerName,
            stickerFormat: extra?.resolvedStickerFormat,
            stickerThumbURL: extra?.thumbUrl,
            stickerPackID: extra?.stickerPackId,
            fileName: extra?.fileName,
            fileSize: extra?.fileSize,
            mimeType: extra?.mimeType,
            status: status ?? (senderId == currentUserId ? "sent" : "received"),
            createdAt: Date(milliseconds: createdAt),
            isOutgoing: senderId == currentUserId,
            burnAfterRead: burnAfterRead,
            burnReadAt: burnReadAt.map(Date.init(milliseconds:)),
            burnExpireAt: burnExpireAt.map(Date.init(milliseconds:)),
            forwardRestricted: forwardRestricted ?? false,
            chat: chat
        )
    }

    func toLocalMessageResolvingEncryption(currentUserId: String?, chat: Chat? = nil) async -> Message {
        let message = toLocalMessage(currentUserId: currentUserId, chat: chat)
        guard msgType == "encrypted" else { return message }

        if senderId == currentUserId {
            message.content = message.type == "text" ? "🔒 已发送加密消息" : message.content
            return message
        }

        do {
            let decrypted = try await E2EEManager.shared.decryptText(content, peerId: senderId)
            if let media = Self.decodeEncryptedMediaMetadata(decrypted) {
                message.type = media.originalType ?? message.type
                message.content = media.displayText
                message.fileName = media.fileName ?? message.fileName
                message.mimeType = media.mimeType ?? message.mimeType
                message.voiceDuration = media.duration ?? message.voiceDuration
                if let waveform = media.waveform, !waveform.isEmpty {
                    message.voiceWaveform = waveform
                }
            } else if message.type == "text" {
                message.content = decrypted
            } else {
                message.content = decrypted
            }
        } catch {
            // Keep ciphertext and secrets out of logs. The failure category is
            // enough to distinguish a stale-device bundle from transport bugs.
            print("[E2EE] decrypt failed message=\(id) sender=\(senderId) error=\(error.localizedDescription)")
            SocketManager.shared.requestEncryptionSessionReset(with: senderId)
            message.content = "🔒 加密消息（等待密钥同步）"
        }
        return message
    }

    private static func decodeEncryptedMediaMetadata(_ text: String) -> EncryptedMediaMetadata? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EncryptedMediaMetadata.self, from: data)
    }

    private struct EncryptedMediaMetadata: Decodable {
        let originalType: String?
        let fileName: String?
        let mimeType: String?
        let duration: Double?
        let waveform: [Double]?

        var displayText: String {
            switch originalType {
            case "image": return "[加密图片]"
            case "voice": return "[加密语音]"
            case "video": return "[加密视频]"
            case "file": return fileName ?? "[加密文件]"
            default: return "🔒 加密消息"
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Date {
    init(milliseconds: Int64) {
        self = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleMillisecondsIfPresent(forKey key: Key) throws -> Int64? {
        if let intValue = try decodeIfPresent(Int64.self, forKey: key) {
            return intValue
        }
        if let doubleValue = try decodeIfPresent(Double.self, forKey: key) {
            return Int64(doubleValue)
        }
        if let stringValue = try decodeIfPresent(String.self, forKey: key) {
            if let intValue = Int64(stringValue) {
                return intValue
            }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: stringValue) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendMultipartField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func appendMultipartFile(fieldName: String, fileName: String, mimeType: String, data: Data, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        append("\r\n")
    }
}
