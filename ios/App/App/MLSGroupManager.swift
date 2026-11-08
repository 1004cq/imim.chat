import CryptoKit
import Foundation
import Security

struct MLSEncryptedPayload: Codable, Hashable {
    let ciphertext: String
    let iv: String
    let tag: String?
}

struct MLSKeyPackage: Codable, Hashable {
    let version: Int
    let cipherSuite: Int
    let initKey: String
    let leafKey: String
    let signature: String
    let userId: String
    let createdAt: Int64
    let expiresAt: Int64
}

struct MLSTreeNode: Codable, Hashable {
    let publicKey: String?
    let hash: String?
}

struct MLSWelcome: Codable, Hashable {
    let groupId: String
    let epoch: Int
    let encryptedGroupInfo: MLSEncryptedPayload
    let leafIndex: Int
    let treeSnapshot: [MLSTreeNode]
    let members: [String: Int]
}

struct MLSApplicationMessage: Codable, Hashable {
    let groupId: String
    let epoch: Int
    let senderLeafIndex: Int
    let ciphertext: MLSEncryptedPayload
    let generation: Int
}

struct MLSWireEnvelope: Codable, Hashable {
    let mls: Bool
    let epoch: Int
    let sender: Int
    let generation: Int
    let ciphertext: MLSEncryptedPayload

    enum CodingKeys: String, CodingKey {
        case mls = "_mls"
        case epoch
        case sender
        case generation = "gen"
        case ciphertext = "ct"
    }
}

private struct MLSStoredEpoch: Codable {
    let epoch: Int
    let groupId: String
    let groupSecret: String
    let applicationSecret: String
    let confirmationKey: String
    let membershipKey: String
    let initSecret: String
    let myLeafIndex: Int
    let members: [String: Int]
    let createdAt: Int64
}

private struct MLSLocalStore: Codable {
    let userId: String
    let identityPrivateKey: String
    let leafPrivateKey: String
    var initPrivateKey: String
    var epochs: [String: MLSStoredEpoch]
    var generations: [String: Int]
}

private struct MLSWelcomeGroupInfo: Codable {
    let groupId: String
    let epoch: Int
    let groupSecret: String
    let applicationSecret: String
    let confirmationKey: String
    let membershipKey: String
    let initSecret: String
    let myLeafIndex: Int
}

enum MLSGroupError: LocalizedError {
    case invalidKeyMaterial
    case invalidWelcome
    case noGroupState
    case waitingForExistingDevice

    var errorDescription: String? {
        switch self {
        case .invalidKeyMaterial: return "MLS 密钥材料无效"
        case .invalidWelcome: return "已有设备返回的 MLS Welcome 无法验证"
        case .noGroupState: return "这台 iPhone 尚未取得该群的 MLS 密钥"
        case .waitingForExistingDevice: return "已请求安全加入；请在已登录的网页端打开该群，等待密钥同步后重试"
        }
    }
}

/// Non-secret, local-only observations. This is not server membership or a
/// claim that all members have verified the group / synchronized this epoch.
struct MLSGroupSecurityInfo: Equatable, Sendable {
    let ownerID: String
    let groupID: String
    let epoch: Int?
    let leafIndex: Int?
    let memberCount: Int?
    let generation: Int?
    let importedAt: Int64?
    let verification: IMIMGroupVerification?
    var hasLocalState: Bool { epoch != nil }
}

enum MLSGroupSecurityError: Error { case accountChanged, unavailable }

/// IMIM application-specific *state comparison*, NOT RFC 9420's epoch_authenticator
/// or a member identity credential. No source key leaves the MLS actor.
struct IMIMGroupVerification: Equatable, Sendable {
    let groupID: String
    let epoch: Int
    let authenticator: String
    var number: String {
        let bytes = stride(from: 0, to: authenticator.count, by: 2).compactMap { index -> UInt8? in
            let start = authenticator.index(authenticator.startIndex, offsetBy: index)
            return UInt8(authenticator[start..<authenticator.index(start, offsetBy: 2)], radix: 16)
        }
        return bytes.map { String(format: "%03d", $0) }.joined(separator: " ")
    }
    struct Payload: Codable {
        let type: String
        let v: Int
        let groupId: String
        let epoch: Int
        let authenticator: String
    }
    var qrPayload: String {
        let payload = Payload(type: "imim-group-epoch-comparison", v: 1, groupId: groupID,
            epoch: epoch, authenticator: authenticator)
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    func matches(_ raw: String) -> Bool {
        guard raw.utf8.count <= 4096, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["type", "v", "groupId", "epoch", "authenticator"]),
              let value = try? JSONDecoder().decode(Payload.self, from: data),
              value.type == "imim-group-epoch-comparison", value.v == 1,
              value.groupId == groupID, value.epoch == epoch,
              value.authenticator.utf8.count == 64,
              value.authenticator.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        // Fixed-length comparison; scanned content is data, never a URL/action.
        return zip(authenticator.utf8, value.authenticator.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func make(groupID: String, epoch: Int, members: [String: Int],
                     groupSecret: String, applicationSecret: String) -> IMIMGroupVerification? {
        let limit = 9_007_199_254_740_991
        func validID(_ value: String, maxBytes: Int = 4096) -> Bool {
            !value.isEmpty && value.utf8.count <= maxBytes &&
                Data(value.precomposedStringWithCanonicalMapping.utf8) == Data(value.utf8)
        }
        guard validID(groupID, maxBytes: 256), (0...limit).contains(epoch),
              !members.isEmpty, members.count <= 100_000,
              Set(members.values).count == members.count,
              members.allSatisfy({ validID($0.key) && (0...limit).contains($0.value) }),
              let secret = Data(base64Encoded: groupSecret), secret.count == 32, secret.base64EncodedString() == groupSecret,
              let application = Data(base64Encoded: applicationSecret), application.count == 32,
              application.base64EncodedString() == applicationSecret else { return nil }
        // Versioned, length-delimited binary context. UTF-8 byte ordering is
        // identical on Swift and Web; locale, local identity, generation, local
        // leaf and import date must not change another member's comparison code.
        var context = Data("imim/group-epoch-comparison/v1\0".utf8)
        func appendInteger(_ value: UInt64, width: Int) {
            for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
                context.append(UInt8(truncatingIfNeeded: value >> shift))
            }
        }
        func appendString(_ value: String) {
            let data = Data(value.utf8)
            appendInteger(UInt64(data.count), width: 4); context.append(data)
        }
        appendString(groupID); appendInteger(UInt64(epoch), width: 8)
        context.append(contentsOf: SHA256.hash(data: application))
        appendInteger(UInt64(members.count), width: 4)
        for member in members.sorted(by: { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }) {
            appendString(member.key); appendInteger(UInt64(member.value), width: 8)
        }
        let mac = HMAC<SHA256>.authenticationCode(for: context, using: SymmetricKey(data: secret))
        return IMIMGroupVerification(groupID: groupID, epoch: epoch,
            authenticator: mac.map { String(format: "%02x", $0) }.joined())
    }
}

/// Cross-platform companion for the Web client's MLS implementation.
/// The server receives only public KeyPackages and encrypted Welcome payloads.
actor MLSGroupManager {
    static let shared = MLSGroupManager()

    private let keychainService = "chat.imim.mls.app.imim.chat"
    private var store: MLSLocalStore?
    private var deletedAccounts = Set<String>()

    /// Read an existing snapshot only. In particular, do NOT call
    /// loadOrCreateStore / prepareGroup here: opening UI must never create keys,
    /// issue a join request, consume a Welcome or alter the current epoch.
    func securityInfo(groupId: String, userId: String) throws -> MLSGroupSecurityInfo {
        guard !groupId.isEmpty, !userId.isEmpty, !deletedAccounts.contains(userId),
              UserDefaults.standard.string(forKey: "current_user_id") == userId else {
            throw MLSGroupSecurityError.accountChanged
        }
        let existing: MLSLocalStore?
        if store?.userId == userId { existing = store }
        else if let bytes = try MLSKeychain.load(service: keychainService, account: userId) {
            guard let decoded = try? JSONDecoder().decode(MLSLocalStore.self, from: bytes),
                  decoded.userId == userId else { throw MLSGroupSecurityError.unavailable }
            existing = decoded // No assignment: don't switch the actor's active store.
        } else { existing = nil }
        guard let local = existing, let value = local.epochs[groupId] else {
            return MLSGroupSecurityInfo(ownerID: userId, groupID: groupId, epoch: nil,
                leafIndex: nil, memberCount: nil, generation: nil, importedAt: nil, verification: nil)
        }
        let generation = local.generations[groupId] ?? 0
        guard value.groupId == groupId, value.epoch >= 0, value.myLeafIndex >= 0,
              generation >= 0 else { throw MLSGroupSecurityError.unavailable }
        return MLSGroupSecurityInfo(ownerID: userId, groupID: groupId,
            epoch: value.epoch, leafIndex: value.myLeafIndex, memberCount: value.members.count,
            generation: generation, importedAt: value.createdAt > 0 ? value.createdAt : nil,
            verification: value.members[userId] == value.myLeafIndex ? IMIMGroupVerification.make(
                groupID: groupId, epoch: value.epoch, members: value.members,
                groupSecret: value.groupSecret, applicationSecret: value.applicationSecret) : nil)
    }

    func removeAccount(userId: String) throws {
        deletedAccounts.insert(userId)
        if store?.userId == userId { store = nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: userId]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MLSGroupError.invalidKeyMaterial }
    }

    func prepareGroup(groupId: String, userId: String, waitForWelcome: Bool = true) async throws -> Bool {
        try loadOrCreateStore(userId: userId)
        let status = try await APIClient.shared.fetchMLSRecoveryStatus(groupId: groupId)
        try Task.checkCancellation()
        guard store?.userId == userId else { throw CancellationError() }

        let deviceId = stableDeviceId()
        let existingWelcome = try await APIClient.shared.fetchMLSDeviceWelcome(
            groupId: groupId,
            deviceId: deviceId
        )
        if try await consumeWelcomeIfReady(existingWelcome, groupId: groupId, userId: userId, expectedEpoch: status.epoch) { return true }
        if store?.epochs[groupId]?.epoch == status.epoch { return true }

        guard let keyPackage = try currentKeyPackage(userId: userId) else {
            throw MLSGroupError.invalidKeyMaterial
        }
        _ = try await APIClient.shared.requestMLSDeviceJoin(
            groupId: groupId,
            deviceId: deviceId,
            keyPackage: keyPackage
        )
        try Task.checkCancellation()
        guard store?.userId == userId else { throw CancellationError() }

        let attempts = waitForWelcome ? 6 : 1
        for attempt in 0..<attempts {
            let response = try await APIClient.shared.fetchMLSDeviceWelcome(
                groupId: groupId,
                deviceId: deviceId
            )
            if try await consumeWelcomeIfReady(response, groupId: groupId, userId: userId, expectedEpoch: status.epoch) { return true }
            if attempt + 1 < attempts {
                try await Task.sleep(for: .seconds(2))
            }
        }
        return false
    }

    private func consumeWelcomeIfReady(_ response: MLSDeviceWelcomeResponse, groupId: String, userId: String, expectedEpoch: Int) async throws -> Bool {
        try Task.checkCancellation()
        guard store?.userId == userId else { throw CancellationError() }
        guard response.ready,
              let requestId = response.requestId,
              let welcome = response.welcome,
              let senderIdentityKey = response.senderIdentityKey else { return false }
        guard welcome.groupId == groupId else { throw MLSGroupError.invalidWelcome }
        if welcome.epoch != expectedEpoch {
            // Joining can advance the group while this request is in flight.
            // Re-read authoritative metadata rather than treating a valid new
            // Welcome as stale, or trusting an arbitrary future epoch.
            let refreshed = try await APIClient.shared.fetchMLSRecoveryStatus(groupId: groupId)
            try Task.checkCancellation()
            guard store?.userId == userId else { throw CancellationError() }
            guard welcome.epoch == refreshed.epoch else { throw MLSGroupError.invalidWelcome }
        }
        // Duplicate deliveries must not reset message generations; a stale
        // response must never downgrade state imported by another actor task.
        if let current = store?.epochs[groupId], current.epoch > welcome.epoch { return false }
        if store?.epochs[groupId]?.epoch != welcome.epoch {
            try processWelcome(welcome, senderIdentityKey: senderIdentityKey)
        }
        try await APIClient.shared.acknowledgeMLSDeviceWelcome(requestId: requestId)
        try Task.checkCancellation()
        guard store?.userId == userId else { throw CancellationError() }
        return true
    }

    func hasState(groupId: String, userId: String) throws -> Bool {
        try loadOrCreateStore(userId: userId)
        return store?.epochs[groupId] != nil
    }

    func encrypt(_ plaintext: String, groupId: String, userId: String) throws -> String {
        try loadOrCreateStore(userId: userId)
        guard var localStore = store, let epoch = localStore.epochs[groupId] else {
            throw MLSGroupError.noGroupState
        }

        let generation = localStore.generations[groupId] ?? 0
        let applicationSecret = try decodeBase64(epoch.applicationSecret)
        let key = try deriveMessageKey(applicationSecret: applicationSecret, generation: generation)
        let aad = try applicationAAD(
            groupId: groupId,
            epoch: epoch.epoch,
            sender: epoch.myLeafIndex,
            generation: generation
        )
        let encrypted = try encryptAESGCM(Data(plaintext.utf8), key: key, aad: aad)
        let wire = MLSWireEnvelope(
            mls: true,
            epoch: epoch.epoch,
            sender: epoch.myLeafIndex,
            generation: generation,
            ciphertext: encrypted
        )

        localStore.generations[groupId] = generation + 1
        try persistStore(localStore)
        store = localStore
        let data = try JSONEncoder().encode(wire)
        guard let result = String(data: data, encoding: .utf8) else {
            throw MLSGroupError.invalidKeyMaterial
        }
        return result
    }

    func decrypt(_ wire: MLSWireEnvelope, groupId: String, userId: String) async throws -> String {
        try loadOrCreateStore(userId: userId)
        if store?.epochs[groupId] == nil || wire.epoch > (store?.epochs[groupId]?.epoch ?? -1) {
            guard try await prepareGroup(groupId: groupId, userId: userId, waitForWelcome: false) else {
                throw MLSGroupError.noGroupState
            }
        }
        let current = store?.epochs[groupId]
        guard let epoch = current?.epoch == wire.epoch ? current : store?.epochs["archive:\(groupId):\(wire.epoch)"] else { throw MLSGroupError.noGroupState }
        let applicationSecret = try decodeBase64(epoch.applicationSecret)
        let key = try deriveMessageKey(applicationSecret: applicationSecret, generation: wire.generation)
        let aad = try applicationAAD(
            groupId: groupId,
            epoch: wire.epoch,
            sender: wire.sender,
            generation: wire.generation
        )
        let plaintext = try decryptAESGCM(wire.ciphertext, key: key, aad: aad)
        guard let result = String(data: plaintext, encoding: .utf8) else {
            throw MLSGroupError.invalidWelcome
        }
        return result
    }

    private func processWelcome(_ welcome: MLSWelcome, senderIdentityKey: String) throws {
        guard var localStore = store,
              let privateData = Data(base64Encoded: localStore.initPrivateKey),
              let senderData = Data(base64Encoded: senderIdentityKey) else {
            throw MLSGroupError.invalidKeyMaterial
        }
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateData)
        let senderKey = try P256.KeyAgreement.PublicKey(rawRepresentation: senderData)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: senderKey)
        let sharedData = sharedSecret.withUnsafeBytes { Data($0) }
        let welcomeKey = hkdf(ikm: sharedData, salt: nil, info: Data("mls-welcome".utf8), length: 32)
        let decrypted = try decryptAESGCM(welcome.encryptedGroupInfo, key: welcomeKey, aad: Data())
        let groupInfo = try JSONDecoder().decode(MLSWelcomeGroupInfo.self, from: decrypted)
        guard groupInfo.groupId == welcome.groupId,
              groupInfo.epoch == welcome.epoch,
              groupInfo.myLeafIndex == welcome.leafIndex else {
            throw MLSGroupError.invalidWelcome
        }

        if let previous = localStore.epochs[welcome.groupId] {
            guard welcome.epoch > previous.epoch else { throw MLSGroupError.invalidWelcome }
            localStore.epochs["archive:\(welcome.groupId):\(previous.epoch)"] = previous
        }

        localStore.epochs[welcome.groupId] = MLSStoredEpoch(
            epoch: welcome.epoch,
            groupId: welcome.groupId,
            groupSecret: groupInfo.groupSecret,
            applicationSecret: groupInfo.applicationSecret,
            confirmationKey: groupInfo.confirmationKey,
            membershipKey: groupInfo.membershipKey,
            initSecret: groupInfo.initSecret,
            myLeafIndex: welcome.leafIndex,
            members: welcome.members,
            createdAt: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        localStore.generations[welcome.groupId] = 0
        try persistStore(localStore)
        store = localStore
    }

    private func loadOrCreateStore(userId: String) throws {
        guard !deletedAccounts.contains(userId) else { throw MLSGroupError.invalidKeyMaterial }
        if store?.userId == userId { return }
        // Only an explicit item-not-found may create keys. A locked/unavailable
        // Keychain or an unreadable existing record must never rotate them.
        if let data = try MLSKeychain.load(service: keychainService, account: userId) {
            guard let existing = try? JSONDecoder().decode(MLSLocalStore.self, from: data),
                  existing.userId == userId else { throw MLSGroupError.invalidKeyMaterial }
            store = existing
            return
        }

        let identity = P256.KeyAgreement.PrivateKey()
        let leaf = P256.KeyAgreement.PrivateKey()
        let initKey = P256.KeyAgreement.PrivateKey()
        let created = MLSLocalStore(
            userId: userId,
            identityPrivateKey: identity.rawRepresentation.base64EncodedString(),
            leafPrivateKey: leaf.rawRepresentation.base64EncodedString(),
            initPrivateKey: initKey.rawRepresentation.base64EncodedString(),
            epochs: [:],
            generations: [:]
        )
        try persistStore(created)
        store = created
    }

    private func currentKeyPackage(userId: String) throws -> MLSKeyPackage? {
        guard let localStore = store,
              let initData = Data(base64Encoded: localStore.initPrivateKey),
              let leafData = Data(base64Encoded: localStore.leafPrivateKey) else { return nil }
        let initKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: initData)
        let leafKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: leafData)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let initPublic = initKey.publicKey.rawRepresentation.base64EncodedString()
        let leafPublic = leafKey.publicKey.rawRepresentation.base64EncodedString()
        let signatureInput = "{\"version\":1,\"cipherSuite\":1,\"initKey\":\"\(initPublic)\",\"leafKey\":\"\(leafPublic)\",\"userId\":\"\(userId)\"}"
        let signature = Data(SHA256.hash(data: Data(signatureInput.utf8))).base64EncodedString()
        return MLSKeyPackage(
            version: 1,
            cipherSuite: 1,
            initKey: initPublic,
            leafKey: leafPublic,
            signature: signature,
            userId: userId,
            createdAt: now,
            expiresAt: now + 30 * 24 * 60 * 60 * 1_000
        )
    }

    private func persistStore(_ localStore: MLSLocalStore) throws {
        guard !deletedAccounts.contains(localStore.userId) else { throw MLSGroupError.invalidKeyMaterial }
        try MLSKeychain.save(
            try JSONEncoder().encode(localStore),
            service: keychainService,
            account: localStore.userId
        )
    }

    private func stableDeviceId() -> String {
        let key = "mls_device_id"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private func deriveMessageKey(applicationSecret: Data, generation: Int) throws -> Data {
        var value = UInt32(clamping: generation).bigEndian
        let context = withUnsafeBytes(of: &value) { Data($0) }
        return expandLabel(secret: applicationSecret, label: "app-key", context: context, length: 16)
    }

    private func expandLabel(secret: Data, label: String, context: Data, length: Int) -> Data {
        let labelData = Data("mls10 \(label)".utf8)
        var info = Data([UInt8((length >> 8) & 0xff), UInt8(length & 0xff), UInt8(labelData.count)])
        info.append(labelData)
        info.append(UInt8(context.count))
        info.append(context)
        return hkdf(ikm: secret, salt: nil, info: info, length: length)
    }

    private func hkdf(ikm: Data, salt: Data?, info: Data, length: Int) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt ?? Data(repeating: 0, count: 32),
            info: info,
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    private func encryptAESGCM(_ plaintext: Data, key: Data, aad: Data) throws -> MLSEncryptedPayload {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key.prefix(key.count > 16 ? 32 : 16)),
            nonce: nonce,
            authenticating: aad
        )
        var combinedCiphertext = sealed.ciphertext
        combinedCiphertext.append(sealed.tag)
        return MLSEncryptedPayload(
            ciphertext: combinedCiphertext.base64EncodedString(),
            iv: Data(nonce).base64EncodedString(),
            tag: ""
        )
    }

    private func decryptAESGCM(_ payload: MLSEncryptedPayload, key: Data, aad: Data) throws -> Data {
        let combined = try decodeBase64(payload.ciphertext)
        let iv = try decodeBase64(payload.iv)
        guard combined.count >= 16 else { throw MLSGroupError.invalidWelcome }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: iv),
            ciphertext: combined.dropLast(16),
            tag: combined.suffix(16)
        )
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: key.prefix(key.count > 16 ? 32 : 16)),
            authenticating: aad
        )
    }

    private func applicationAAD(groupId: String, epoch: Int, sender: Int, generation: Int) throws -> Data {
        let encoded = try JSONEncoder().encode([groupId])
        guard let array = String(data: encoded, encoding: .utf8), array.count >= 2 else {
            throw MLSGroupError.invalidKeyMaterial
        }
        let quotedGroupId = String(array.dropFirst().dropLast())
        return Data("{\"groupId\":\(quotedGroupId),\"epoch\":\(epoch),\"sender\":\(sender),\"generation\":\(generation)}".utf8)
    }

    private func decodeBase64(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value) else { throw MLSGroupError.invalidKeyMaterial }
        return data
    }
}

private enum MLSKeychain {
    static func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MLSGroupError.invalidKeyMaterial
        }
        return data
    }

    static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw MLSGroupError.invalidKeyMaterial
            }
        } else if status != errSecSuccess {
            throw MLSGroupError.invalidKeyMaterial
        }
    }
}
