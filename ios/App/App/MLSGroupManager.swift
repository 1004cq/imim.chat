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

/// Cross-platform companion for the Web client's MLS implementation.
/// The server receives only public KeyPackages and encrypted Welcome payloads.
actor MLSGroupManager {
    static let shared = MLSGroupManager()

    private let keychainService = "chat.imim.mls.app.imim.chat"
    private var store: MLSLocalStore?
    private var deletedAccounts = Set<String>()

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
        if store?.epochs[groupId] != nil { return true }

        let deviceId = stableDeviceId()
        let existingWelcome = try await APIClient.shared.fetchMLSDeviceWelcome(
            groupId: groupId,
            deviceId: deviceId
        )
        if try await consumeWelcomeIfReady(existingWelcome) { return true }

        guard let keyPackage = try currentKeyPackage(userId: userId) else {
            throw MLSGroupError.invalidKeyMaterial
        }
        _ = try await APIClient.shared.requestMLSDeviceJoin(
            groupId: groupId,
            deviceId: deviceId,
            keyPackage: keyPackage
        )

        let attempts = waitForWelcome ? 6 : 1
        for attempt in 0..<attempts {
            let response = try await APIClient.shared.fetchMLSDeviceWelcome(
                groupId: groupId,
                deviceId: deviceId
            )
            if try await consumeWelcomeIfReady(response) { return true }
            if attempt + 1 < attempts {
                try await Task.sleep(for: .seconds(2))
            }
        }
        return false
    }

    private func consumeWelcomeIfReady(_ response: MLSDeviceWelcomeResponse) async throws -> Bool {
        guard response.ready,
              let requestId = response.requestId,
              let welcome = response.welcome,
              let senderIdentityKey = response.senderIdentityKey else { return false }
        try processWelcome(welcome, senderIdentityKey: senderIdentityKey)
        try await APIClient.shared.acknowledgeMLSDeviceWelcome(requestId: requestId)
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
        store = localStore
        try persistStore(localStore)
        let data = try JSONEncoder().encode(wire)
        guard let result = String(data: data, encoding: .utf8) else {
            throw MLSGroupError.invalidKeyMaterial
        }
        return result
    }

    func decrypt(_ wire: MLSWireEnvelope, groupId: String, userId: String) throws -> String {
        try loadOrCreateStore(userId: userId)
        guard let epoch = store?.epochs[groupId] else { throw MLSGroupError.noGroupState }
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
        store = localStore
        try persistStore(localStore)
    }

    private func loadOrCreateStore(userId: String) throws {
        guard !deletedAccounts.contains(userId) else { throw MLSGroupError.invalidKeyMaterial }
        if store?.userId == userId { return }
        if let data = try? MLSKeychain.load(service: keychainService, account: userId),
           let existing = try? JSONDecoder().decode(MLSLocalStore.self, from: data) {
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
        store = created
        try persistStore(created)
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
        guard status == errSecSuccess else { throw MLSGroupError.invalidKeyMaterial }
        return result as? Data
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
