import CryptoKit
import Foundation
import Security

struct E2EEMediaEncryptionResult: Hashable {
    let encryptedData: Data
    let envelopeString: String
    let encryptedFileName: String
    let metadata: EncryptedMediaMetadata
}

struct SignalEncryptedPayload: Codable, Hashable {
    let ciphertext: String
    let iv: String
    let tag: String
}

struct SignalEnvelope: Codable, Hashable {
    /// Version 2 adds the recipient PreKey identifiers required for a receiver to
    /// establish the same X3DH session as the sender.
    let version: Int?
    let type: String
    let senderRegistrationId: Int
    let senderIdentityKey: String
    let senderEphemeralKey: String?
    let recipientSignedPreKeyId: Int?
    let recipientOneTimePreKeyId: Int?
    // The deployed Web client used these names before v2. Keep both on send.
    var usedSignedPreKeyId: Int? = nil
    var usedOneTimePreKeyId: Int? = nil
    let senderRatchetKey: String
    let previousCounter: Int
    let counter: Int
    let ciphertext: SignalEncryptedPayload
    let timestamp: Int64
}

struct E2EEPreKeyBundle: Codable, Hashable {
    let registrationId: Int
    let identityKey: String
    var signingPublicKey: String? = nil
    let signedPreKeyId: Int
    let signedPreKey: String
    let signedPreKeySignature: String
    let oneTimePreKeyId: Int?
    let oneTimePreKey: String?
}

struct E2EELocalPreKeyBundle: Codable, Hashable {
    let registrationId: Int
    let identityKey: String
    var signingPublicKey: String? = nil
    let signedPreKeyId: Int
    let signedPreKey: String
    let signedPreKeySignature: String
}

struct E2EEDiagnostics: Equatable {
    let registrationId: Int
    let identityFingerprint: String
    let availablePreKeyCount: Int
}

struct E2EEPreKeyUpload: Codable, Hashable {
    let keyId: Int
    let publicKey: String
}

enum E2EEError: LocalizedError {
    case missingCurrentUser
    case nativeSignalUnavailable
    case mediaEncryptionUnavailable
    case invalidEnvelope
    case invalidRemoteBundle
    case missingOneTimePreKey
    case keyAgreementFailed
    case unsupportedProtocol

    var errorDescription: String? {
        switch self {
        case .missingCurrentUser:
            return "未登录，无法初始化端到端加密密钥。"
        case .nativeSignalUnavailable:
            return "端到端加密初始化失败，已阻止发送。"
        case .mediaEncryptionUnavailable:
            return "iOS 原生端尚未实现媒体密文上传。语音/图片/文件不能以明文发送。"
        case .invalidEnvelope:
            return "加密信封格式无效，已阻止发送。"
        case .invalidRemoteBundle:
            return "对方尚未注册 E2EE 密钥，暂时无法发送加密消息。"
        case .missingOneTimePreKey:
            return "一次性预密钥不可用，已保留当前安全会话，请让对方重新发送。"
        case .keyAgreementFailed:
            return "端到端加密密钥协商失败，已阻止发送。"
        case .unsupportedProtocol:
            return "加密会话需要重新建立，请让双方更新到最新版本后重试。"
        }
    }
}

final class E2EEManager {
    static let shared = E2EEManager()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let keychain = E2EEKeychainStore()
    private let stateQueue = DispatchQueue(label: "chat.imim.e2ee.state")
    private let operations = E2EEOperationQueue()
    private var deletedAccounts = Set<String>()

    private init() {}

#if E2EE_REGRESSION_TESTS
    // The CLI harness compiles the production implementation with a memory-only
    // store. This code is excluded from all app builds and never reads Keychain.
    static func regressionInstance() -> E2EEManager { E2EEManager() }
    func regressionBundle(userId: String) throws -> E2EEPreKeyBundle {
        let registration = try requireRegistration(userId: userId)
        let key = try keychain.loadPreKeys(userId: userId).first
        return E2EEPreKeyBundle(registrationId: registration.registrationId,
            identityKey: registration.identityKeyPair.pubKey,
            signingPublicKey: registration.signingKeyPair?.pubKey,
            signedPreKeyId: registration.signedPreKey.id, signedPreKey: registration.signedPreKey.keyPair.pubKey,
            signedPreKeySignature: registration.signedPreKey.signature,
            oneTimePreKeyId: key?.id, oneTimePreKey: key?.keyPair.pubKey)
    }
    func regressionState(userId: String, peerId: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(keychain.loadSession(userId: userId, peerId: peerId))
    }
#endif

    func bootstrapForCurrentUser() async {
        do {
            try await synchronizeCurrentUser()
        } catch {
            print("[E2EE] bootstrap failed: \(error.localizedDescription)")
        }
    }

    /// Registers the keys currently held by this installation before messages
    /// are sent or retried. The error is surfaced to the calling UI so users do
    /// not get a false impression that an encrypted message was delivered.
    func synchronizeCurrentUser(forceBundleRegistration: Bool = false) async throws {
        guard let userId = UserDefaults.standard.string(forKey: "current_user_id"), !userId.isEmpty else {
            throw E2EEError.missingCurrentUser
        }
        try await operations.perform {
            try await self.initializeAndRegisterIfNeeded(userId: userId, forceBundleRegistration: forceBundleRegistration)
        }
    }

    /// Discards only the ratchet shared with one peer. The next outgoing
    /// message is a fresh PreKey message; historical ciphertext stays intact.
    func resetSession(with peerId: String) async throws {
        guard let userId = UserDefaults.standard.string(forKey: "current_user_id"), !userId.isEmpty else {
            throw E2EEError.missingCurrentUser
        }
        try await operations.perform {
            try self.keychain.deleteSession(userId: userId, peerId: peerId)
        }
    }

    /// Exposes only non-secret metadata for the native security settings screen.
    func removeAccountKeys(userId: String) async throws {
        try await operations.perform {
            self.deletedAccounts.insert(userId)
            try self.keychain.removeAccountKeys(userId: userId)
        }
    }

    func diagnosticsForCurrentUser() -> E2EEDiagnostics? {
        guard let userId = UserDefaults.standard.string(forKey: "current_user_id"), !userId.isEmpty else {
            return nil
        }

        return stateQueue.sync {
            guard let registration = try? keychain.loadRegistration(userId: userId) else {
                return nil
            }
            let preKeys = (try? keychain.loadPreKeys(userId: userId)) ?? []
            let hash = SHA256.hash(data: Data(registration.identityKeyPair.pubKey.utf8))
                .map { String(format: "%02X", $0) }
                .joined()
            let fingerprint = stride(from: 0, to: min(hash.count, 32), by: 4)
                .map { index in
                    let start = hash.index(hash.startIndex, offsetBy: index)
                    let end = hash.index(start, offsetBy: min(4, hash.distance(from: start, to: hash.endIndex)))
                    return String(hash[start..<end])
                }
                .joined(separator: " ")

            return E2EEDiagnostics(
                registrationId: registration.registrationId,
                identityFingerprint: fingerprint,
                availablePreKeyCount: preKeys.count
            )
        }
    }

    func encryptText(_ plaintext: String, peerId: String, structuredPayload: Bool = false) async throws -> String {
        guard let userId = UserDefaults.standard.string(forKey: "current_user_id"), !userId.isEmpty else {
            throw E2EEError.missingCurrentUser
        }

        let wireText: String
        if structuredPayload {
            wireText = plaintext
        } else {
            let data = try JSONSerialization.data(withJSONObject: ["content": plaintext, "msgType": "text"])
            wireText = String(decoding: data, as: UTF8.self)
        }
        let envelope = try await operations.perform {
            try await self.initializeAndRegisterIfNeeded(userId: userId)
            return try await self.encryptTextLocked(wireText, userId: userId, peerId: peerId)
        }
        let data = try JSONEncoder().encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw E2EEError.invalidEnvelope
        }
        return json
    }

    func validateEnvelopeString(_ envelopeString: String) throws -> String {
        guard let data = envelopeString.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(SignalEnvelope.self, from: data),
              envelope.version == 2,
              (envelope.type == "prekey" || envelope.type == "message"),
              !envelope.senderIdentityKey.isEmpty,
              !envelope.senderRatchetKey.isEmpty,
              !envelope.ciphertext.ciphertext.isEmpty,
              !envelope.ciphertext.iv.isEmpty,
              (envelope.type != "prekey" || (envelope.senderEphemeralKey != nil && envelope.recipientSignedPreKeyId != nil)) else {
            throw E2EEError.invalidEnvelope
        }
        return envelopeString
    }

    func decryptText(_ envelopeString: String, peerId: String) async throws -> String {
        guard let data = envelopeString.data(using: .utf8) else {
            throw E2EEError.invalidEnvelope
        }
        let envelope = try JSONDecoder().decode(SignalEnvelope.self, from: data)
        guard let userId = UserDefaults.standard.string(forKey: "current_user_id"), !userId.isEmpty else {
            throw E2EEError.missingCurrentUser
        }
        let plaintext = try await operations.perform {
            // Existing local keys are sufficient for history. Do not make
            // decryption depend on a successful key-directory network request.
            if try self.keychain.loadRegistration(userId: userId) == nil {
                try await self.initializeAndRegisterIfNeeded(userId: userId)
            }
            return try await self.decryptTextLocked(envelope, userId: userId, peerId: peerId)
        }
        // Web text messages contain a JSON application payload, not raw text.
        if let bytes = plaintext.data(using: .utf8),
           let payload = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           payload["msgType"] as? String == "text", let content = payload["content"] as? String {
            return content
        }
        return plaintext
    }

    func encryptMediaPayload(
        _ data: Data,
        peerId: String,
        originalType: String,
        fileName: String,
        mimeType: String,
        duration: Double? = nil,
        waveform: [Double]? = nil
    ) async throws -> E2EEMediaEncryptionResult {
        guard !data.isEmpty else { throw E2EEError.mediaEncryptionUnavailable }

        let mediaKeyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let nonceData = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let sealed = try AES.GCM.seal(
            data,
            using: SymmetricKey(data: mediaKeyData),
            nonce: AES.GCM.Nonce(data: nonceData)
        )
        let encryptedData = sealed.ciphertext + sealed.tag
        let metadata = EncryptedMediaMetadata(
            version: 1,
            originalType: originalType,
            fileName: fileName,
            mimeType: mimeType,
            byteSize: data.count,
            mediaKey: mediaKeyData.base64EncodedString(),
            mediaIV: nonceData.base64EncodedString(),
            mediaTag: sealed.tag.base64EncodedString(),
            duration: duration,
            waveform: waveform
        )
        let metadataData = try encoder.encode(metadata)
        guard let metadataString = String(data: metadataData, encoding: .utf8) else {
            throw E2EEError.invalidEnvelope
        }
        let envelope = try await encryptText(metadataString, peerId: peerId, structuredPayload: true)
        return E2EEMediaEncryptionResult(
            encryptedData: encryptedData,
            envelopeString: envelope,
            encryptedFileName: "\(fileName).enc",
            metadata: metadata
        )
    }

    private func initializeAndRegisterIfNeeded(userId: String, forceBundleRegistration: Bool = false) async throws {
        guard !deletedAccounts.contains(userId) else { throw E2EEError.missingCurrentUser }
        let didCreateRegistration: Bool
        if try keychain.loadRegistration(userId: userId) == nil {
            let identity = P256.KeyAgreement.PrivateKey()
            let signedPreKey = P256.KeyAgreement.PrivateKey()
            let signedSignature = signedPreKey.publicKey.derRepresentation.base64EncodedString()
            let registration = E2EERegistration(
                registrationId: Int.random(in: 1...16_380),
                identityKeyPair: E2EEKeyPair(pubKey: identity.publicKey.derRepresentation.base64EncodedString(), privKey: identity.derRepresentation.base64EncodedString()),
                signedPreKey: E2EESignedPreKey(id: 1, keyPair: E2EEKeyPair(pubKey: signedPreKey.publicKey.derRepresentation.base64EncodedString(), privKey: signedPreKey.derRepresentation.base64EncodedString()), signature: signedSignature),
                nextPreKeyId: 20
            )
            try keychain.saveRegistration(registration, userId: userId)
            _ = try generatePreKeys(userId: userId, startId: 0, count: 20)
            didCreateRegistration = true
        } else {
            didCreateRegistration = false
        }

        // Legacy builds put the public key itself in the signature field.
        // Re-sign the SAME signed prekey; never rotate private keys on upgrade.
        var upgraded = try requireRegistration(userId: userId)
        let needsSigningMigration = upgraded.signingKeyPair == nil
        if needsSigningMigration {
            let signing = P256.Signing.PrivateKey()
            upgraded.signingKeyPair = E2EEKeyPair(pubKey: signing.publicKey.derRepresentation.base64EncodedString(), privKey: signing.derRepresentation.base64EncodedString())
            guard let publicData = Data(base64Encoded: upgraded.signedPreKey.keyPair.pubKey) else {
                throw E2EEError.invalidRemoteBundle
            }
            upgraded.signedPreKey = E2EESignedPreKey(id: upgraded.signedPreKey.id, keyPair: upgraded.signedPreKey.keyPair, signature: try signing.signature(for: publicData).rawRepresentation.base64EncodedString())
            try keychain.saveRegistration(upgraded, userId: userId)
        }

        let registration = try requireRegistration(userId: userId)
        let markerKey = "e2ee_bundle_registration_id_\(userId)"
        let poolSchemaMarkerKey = "e2ee_prekey_pool_schema_version_\(userId)"
        let requiresPoolReconciliation = UserDefaults.standard.integer(forKey: poolSchemaMarkerKey) < 2
        if forceBundleRegistration
            || needsSigningMigration
            || didCreateRegistration
            || UserDefaults.standard.integer(forKey: markerKey) != registration.registrationId
            || requiresPoolReconciliation {
            try await registerBundle(userId: userId)
            UserDefaults.standard.set(registration.registrationId, forKey: markerKey)
            // Reconcile once on upgrade. Server tombstones must exclude issued
            // IDs even when this installation re-uploads their public halves.
            UserDefaults.standard.set(2, forKey: poolSchemaMarkerKey)
            print("[E2EE] bundle registered force=\(forceBundleRegistration) registration=\(registration.registrationId)")
        }

        // A network/auth failure is not an empty pool. It must not cause new
        // private keys to be minted for every historical decrypt attempt.
        guard let count = try? await APIClient.shared.fetchE2EEPreKeyCount(userId: userId) else { return }
        if count < 5 {
            let startId = max(registration.nextPreKeyId, Int(Date().timeIntervalSince1970) % 100_000)
            let newKeys = try generatePreKeys(userId: userId, startId: startId, count: 20)
            var updated = registration
            updated.nextPreKeyId = startId + 20
            try keychain.saveRegistration(updated, userId: userId)
            try await APIClient.shared.replenishE2EEPreKeys(userId: userId, preKeys: newKeys)
        }
    }

    private func registerBundle(userId: String) async throws {
        let registration = try requireRegistration(userId: userId)
        let preKeys = try keychain.loadPreKeys(userId: userId).map {
            E2EEPreKeyUpload(keyId: $0.id, publicKey: $0.keyPair.pubKey)
        }
        let bundle = E2EELocalPreKeyBundle(
            registrationId: registration.registrationId,
            identityKey: registration.identityKeyPair.pubKey,
            signingPublicKey: registration.signingKeyPair?.pubKey,
            signedPreKeyId: registration.signedPreKey.id,
            signedPreKey: registration.signedPreKey.keyPair.pubKey,
            signedPreKeySignature: registration.signedPreKey.signature
        )
        try await APIClient.shared.registerE2EEBundle(userId: userId, bundle: bundle, preKeys: preKeys)
    }

    private func encryptTextLocked(_ plaintext: String, userId: String, peerId: String) async throws -> SignalEnvelope {
        var session = try keychain.loadSession(userId: userId, peerId: peerId)
        if session?.ratchetState.protocolVersion != 2 {
            try keychain.deleteSession(userId: userId, peerId: peerId)
            session = nil
        }
        if session == nil {
            let remoteBundle = try await APIClient.shared.fetchE2EEBundle(userId: peerId)
            session = try establishSession(userId: userId, peerId: peerId, bundle: remoteBundle)
        }

        guard var sessionData = session else {
            throw E2EEError.keyAgreementFailed
        }

        let chainKey = Data(base64Encoded: sessionData.ratchetState.sendChainKey ?? "") ?? Data()
        guard !chainKey.isEmpty else { throw E2EEError.keyAgreementFailed }
        let derived = deriveMessageKeys(chainKey: chainKey)
        let encrypted = try aesEncrypt(Data(plaintext.utf8), key: derived.messageKey)

        sessionData.ratchetState.sendChainKey = derived.nextChainKey.base64EncodedString()
        sessionData.ratchetState.sendCounter += 1
        let isFirstMessage = !sessionData.ratchetState.sentPreKey
        sessionData.ratchetState.sentPreKey = true
        try keychain.saveSession(sessionData, userId: userId, peerId: peerId)

        return SignalEnvelope(
            version: 2,
            type: isFirstMessage ? "prekey" : "message",
            senderRegistrationId: sessionData.localRegistrationId,
            senderIdentityKey: sessionData.localIdentityKey,
            senderEphemeralKey: isFirstMessage ? sessionData.ephemeralKey : nil,
            recipientSignedPreKeyId: isFirstMessage ? sessionData.recipientSignedPreKeyId : nil,
            recipientOneTimePreKeyId: isFirstMessage ? sessionData.recipientOneTimePreKeyId : nil,
            usedSignedPreKeyId: isFirstMessage ? sessionData.recipientSignedPreKeyId : nil,
            usedOneTimePreKeyId: isFirstMessage ? sessionData.recipientOneTimePreKeyId : nil,
            senderRatchetKey: sessionData.ratchetState.dhSendingKeyPair.pubKey,
            previousCounter: sessionData.ratchetState.previousSendCounter,
            counter: sessionData.ratchetState.sendCounter,
            ciphertext: encrypted,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }

    private func decryptTextLocked(_ envelope: SignalEnvelope, userId: String, peerId: String) async throws -> String {
        guard envelope.version == nil || envelope.version == 2 else {
            throw E2EEError.unsupportedProtocol
        }
        guard envelope.counter > 0, envelope.previousCounter >= 0 else { throw E2EEError.invalidEnvelope }
        if let native = envelope.recipientSignedPreKeyId, let web = envelope.usedSignedPreKeyId, native != web { throw E2EEError.invalidEnvelope }
        if let native = envelope.recipientOneTimePreKeyId, let web = envelope.usedOneTimePreKeyId, native != web { throw E2EEError.invalidEnvelope }

        var session = try keychain.loadSession(userId: userId, peerId: peerId)
        var acceptedPreKeySession = false
        if session?.ratchetState.protocolVersion != 2 {
            session = nil
        }
        let cacheKey = "\(envelope.senderRatchetKey):\(envelope.counter)"
        if var existing = session, let skippedKey = existing.ratchetState.skippedMessageKeys[cacheKey],
           let key = Data(base64Encoded: skippedKey) {
            let plaintext = try aesDecrypt(envelope.ciphertext, key: key)
            existing.ratchetState.skippedMessageKeys.removeValue(forKey: cacheKey)
            try keychain.saveSession(existing, userId: userId, peerId: peerId)
            return String(decoding: plaintext, as: UTF8.self)
        }
        if session?.ratchetState.retiredRatchetKeys.contains(envelope.senderRatchetKey) == true {
            throw E2EEError.invalidEnvelope
        }

        // Build a replacement X3DH session in memory and commit it only after
        // AES-GCM authentication succeeds. Historical/replayed PreKey messages
        // must never delete a currently working ratchet before they prove that
        // this device still owns every referenced private key.
        if envelope.type == "prekey" && envelope.senderRatchetKey != session?.ratchetState.dhReceivingKey {
            if let existing = session, existing.ephemeralKey != nil,
               existing.ratchetState.receiveChainKey == nil,
               existing.ratchetState.remoteIdentityKey == envelope.senderIdentityKey,
               existing.ratchetState.remoteRegistrationId == envelope.senderRegistrationId,
               envelope.senderIdentityKey <= existing.localIdentityKey {
                // Same deterministic initiator tie-break as the Web client.
                throw E2EEError.invalidEnvelope
            }
            let previous = session?.ratchetState
            session = try acceptPreKeyMessage(envelope, userId: userId, peerId: peerId)
            session?.ratchetState.retiredRatchetKeys = Array(((previous?.retiredRatchetKeys ?? []) + (previous?.dhReceivingKey.map { [$0] } ?? [])).suffix(128))
            acceptedPreKeySession = true
        }
        guard var session else {
            throw E2EEError.unsupportedProtocol
        }

        if envelope.senderRatchetKey != session.ratchetState.dhReceivingKey {
            try skipReceiveKeys(&session.ratchetState, until: envelope.previousCounter)
            if let previous = session.ratchetState.dhReceivingKey {
                session.ratchetState.retiredRatchetKeys = Array((session.ratchetState.retiredRatchetKeys + [previous]).suffix(128))
            }
            session = try performDHRatchet(session, newRemoteRatchetKey: envelope.senderRatchetKey)
        }
        guard envelope.counter > session.ratchetState.receiveCounter else { throw E2EEError.invalidEnvelope }
        try skipReceiveKeys(&session.ratchetState, until: envelope.counter - 1)
        guard let chainSource = session.ratchetState.receiveChainKey,
              let chainKey = Data(base64Encoded: chainSource) else {
            throw E2EEError.keyAgreementFailed
        }
        let derived = deriveMessageKeys(chainKey: chainKey)
        let plaintext = try aesDecrypt(envelope.ciphertext, key: derived.messageKey)

        session.ratchetState.receiveChainKey = derived.nextChainKey.base64EncodedString()
        session.ratchetState.receiveCounter += 1
        try keychain.saveSession(session, userId: userId, peerId: peerId)
        if acceptedPreKeySession, let usedPreKeyId = session.usedOneTimePreKeyId {
            try keychain.removePreKey(id: usedPreKeyId, userId: userId)
        }

        return String(decoding: plaintext, as: UTF8.self)
    }

    private func establishSession(userId: String, peerId: String, bundle: E2EEPreKeyBundle) throws -> E2EESessionData {
        let registration = try requireRegistration(userId: userId)
        guard let identityPrivateData = Data(base64Encoded: registration.identityKeyPair.privKey),
              let remoteIdentityData = Data(base64Encoded: bundle.identityKey),
              let remoteSignedPreKeyData = Data(base64Encoded: bundle.signedPreKey) else {
            throw E2EEError.invalidRemoteBundle
        }

        let identityPrivate = try P256.KeyAgreement.PrivateKey(derRepresentation: identityPrivateData)
        let remoteIdentityPublic = try P256.KeyAgreement.PublicKey(derRepresentation: remoteIdentityData)
        let remoteSignedPreKeyPublic = try P256.KeyAgreement.PublicKey(derRepresentation: remoteSignedPreKeyData)
        guard let signingData = Data(base64Encoded: bundle.signingPublicKey ?? ""),
              let signatureData = Data(base64Encoded: bundle.signedPreKeySignature),
              (bundle.oneTimePreKeyId == nil) == (bundle.oneTimePreKey == nil) else { throw E2EEError.invalidRemoteBundle }
        let signer = try P256.Signing.PublicKey(derRepresentation: signingData)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureData)
        guard signer.isValidSignature(signature, for: remoteSignedPreKeyData) else { throw E2EEError.invalidRemoteBundle }
        let ephemeral = P256.KeyAgreement.PrivateKey()

        var dhResults = Data()
        dhResults.append(try sharedSecret(identityPrivate, remoteSignedPreKeyPublic))
        dhResults.append(try sharedSecret(ephemeral, remoteIdentityPublic))
        dhResults.append(try sharedSecret(ephemeral, remoteSignedPreKeyPublic))

        if let oneTimePreKey = bundle.oneTimePreKey,
           let oneTimeData = Data(base64Encoded: oneTimePreKey) {
            let remoteOneTimePublic = try P256.KeyAgreement.PublicKey(derRepresentation: oneTimeData)
            dhResults.append(try sharedSecret(ephemeral, remoteOneTimePublic))
        }

        let rootKey = hkdf(input: dhResults, salt: Data(repeating: 0, count: 32), info: Data("imim-x3dh".utf8), length: 32)
        let sendRatchet = P256.KeyAgreement.PrivateKey()
        let dhSend = try sharedSecret(sendRatchet, remoteSignedPreKeyPublic)
        let derived = hkdf(input: rootKey + dhSend, salt: Data(repeating: 0, count: 32), info: Data("imim-chain".utf8), length: 64)
        let newRootKey = derived.prefix(32)
        let sendChainKey = derived.suffix(32)

        let session = E2EESessionData(
            localRegistrationId: registration.registrationId,
            localIdentityKey: registration.identityKeyPair.pubKey,
            ephemeralKey: ephemeral.publicKey.derRepresentation.base64EncodedString(),
            usedOneTimePreKeyId: bundle.oneTimePreKeyId,
            recipientSignedPreKeyId: bundle.signedPreKeyId,
            recipientOneTimePreKeyId: bundle.oneTimePreKeyId,
            ratchetState: E2EERatchetState(
                dhSendingKeyPair: E2EEKeyPair(pubKey: sendRatchet.publicKey.derRepresentation.base64EncodedString(), privKey: sendRatchet.derRepresentation.base64EncodedString()),
                dhReceivingKey: bundle.signedPreKey,
                rootKey: Data(newRootKey).base64EncodedString(),
                sendChainKey: Data(sendChainKey).base64EncodedString(),
                sendCounter: 0,
                receiveChainKey: nil,
                receiveCounter: 0,
                previousSendCounter: 0,
                remoteIdentityKey: bundle.identityKey,
                remoteRegistrationId: bundle.registrationId,
                protocolVersion: 2,
                sentPreKey: false
            )
        )
        try keychain.saveSession(session, userId: userId, peerId: peerId)
        return session
    }

    /// Accept the first v2 PreKey envelope with our private identity/prekeys.
    /// This is the missing inverse of `establishSession` and makes the first Web/iOS
    /// delivery derive the same root and receiving chain on both platforms.
    private func acceptPreKeyMessage(_ envelope: SignalEnvelope, userId: String, peerId: String) throws -> E2EESessionData {
        guard let ephemeralKey = envelope.senderEphemeralKey,
              let signedPreKeyId = envelope.recipientSignedPreKeyId ?? envelope.usedSignedPreKeyId,
              signedPreKeyId == (try requireRegistration(userId: userId)).signedPreKey.id,
              let identityPrivateData = Data(base64Encoded: try requireRegistration(userId: userId).identityKeyPair.privKey),
              let signedPrivateData = Data(base64Encoded: try requireRegistration(userId: userId).signedPreKey.keyPair.privKey),
              let senderIdentityData = Data(base64Encoded: envelope.senderIdentityKey),
              let senderEphemeralData = Data(base64Encoded: ephemeralKey),
              let senderRatchetData = Data(base64Encoded: envelope.senderRatchetKey) else {
            throw E2EEError.invalidRemoteBundle
        }

        let registration = try requireRegistration(userId: userId)
        let identityPrivate = try P256.KeyAgreement.PrivateKey(derRepresentation: identityPrivateData)
        let signedPrivate = try P256.KeyAgreement.PrivateKey(derRepresentation: signedPrivateData)
        let senderIdentity = try P256.KeyAgreement.PublicKey(derRepresentation: senderIdentityData)
        let senderEphemeral = try P256.KeyAgreement.PublicKey(derRepresentation: senderEphemeralData)
        let senderRatchet = try P256.KeyAgreement.PublicKey(derRepresentation: senderRatchetData)

        var dhResults = Data()
        dhResults.append(try sharedSecret(signedPrivate, senderIdentity))
        dhResults.append(try sharedSecret(identityPrivate, senderEphemeral))
        dhResults.append(try sharedSecret(signedPrivate, senderEphemeral))

        if let preKeyId = envelope.recipientOneTimePreKeyId ?? envelope.usedOneTimePreKeyId {
            guard let preKey = try keychain.loadPreKeys(userId: userId).first(where: { $0.id == preKeyId }),
                  let privateData = Data(base64Encoded: preKey.keyPair.privKey) else {
                throw E2EEError.missingOneTimePreKey
            }
            let oneTimePrivate = try P256.KeyAgreement.PrivateKey(derRepresentation: privateData)
            dhResults.append(try sharedSecret(oneTimePrivate, senderEphemeral))
            // Only consume the key after AES-GCM authentication has succeeded.
            // A stale bundle must remain retryable after a failed decrypt.
        }

        let salt = Data(repeating: 0, count: 32)
        let initialRoot = hkdf(input: dhResults, salt: salt, info: Data("imim-x3dh".utf8), length: 32)
        let receiveDerived = hkdf(
            input: initialRoot + (try sharedSecret(signedPrivate, senderRatchet)),
            salt: salt,
            info: Data("imim-chain".utf8),
            length: 64
        )
        let responseRatchet = P256.KeyAgreement.PrivateKey()
        let sendDerived = hkdf(
            input: Data(receiveDerived.prefix(32)) + (try sharedSecret(responseRatchet, senderRatchet)),
            salt: salt,
            info: Data("imim-ratchet".utf8),
            length: 64
        )

        let session = E2EESessionData(
            localRegistrationId: registration.registrationId,
            localIdentityKey: registration.identityKeyPair.pubKey,
            ephemeralKey: nil,
            usedOneTimePreKeyId: envelope.recipientOneTimePreKeyId ?? envelope.usedOneTimePreKeyId,
            recipientSignedPreKeyId: nil,
            recipientOneTimePreKeyId: nil,
            ratchetState: E2EERatchetState(
                dhSendingKeyPair: E2EEKeyPair(pubKey: responseRatchet.publicKey.derRepresentation.base64EncodedString(), privKey: responseRatchet.derRepresentation.base64EncodedString()),
                dhReceivingKey: envelope.senderRatchetKey,
                rootKey: Data(sendDerived.prefix(32)).base64EncodedString(),
                sendChainKey: Data(sendDerived.suffix(32)).base64EncodedString(),
                sendCounter: 0,
                receiveChainKey: Data(receiveDerived.suffix(32)).base64EncodedString(),
                receiveCounter: 0,
                previousSendCounter: 0,
                remoteIdentityKey: envelope.senderIdentityKey,
                remoteRegistrationId: envelope.senderRegistrationId,
                protocolVersion: 2,
                sentPreKey: true
            )
        )
        return session
    }

    private func performDHRatchet(_ session: E2EESessionData, newRemoteRatchetKey: String) throws -> E2EESessionData {
        guard let remoteData = Data(base64Encoded: newRemoteRatchetKey),
              let oldSendPrivateData = Data(base64Encoded: session.ratchetState.dhSendingKeyPair.privKey),
              let rootData = Data(base64Encoded: session.ratchetState.rootKey) else {
            throw E2EEError.keyAgreementFailed
        }
        let remote = try P256.KeyAgreement.PublicKey(derRepresentation: remoteData)
        let oldSend = try P256.KeyAgreement.PrivateKey(derRepresentation: oldSendPrivateData)
        let salt = Data(repeating: 0, count: 32)
        let receiveDerived = hkdf(input: rootData + (try sharedSecret(oldSend, remote)), salt: salt, info: Data("imim-ratchet".utf8), length: 64)
        let newSend = P256.KeyAgreement.PrivateKey()
        let sendDerived = hkdf(input: Data(receiveDerived.prefix(32)) + (try sharedSecret(newSend, remote)), salt: salt, info: Data("imim-ratchet".utf8), length: 64)

        var updated = session
        updated.ratchetState.previousSendCounter = updated.ratchetState.sendCounter
        updated.ratchetState.sendCounter = 0
        updated.ratchetState.receiveCounter = 0
        updated.ratchetState.dhReceivingKey = newRemoteRatchetKey
        updated.ratchetState.dhSendingKeyPair = E2EEKeyPair(pubKey: newSend.publicKey.derRepresentation.base64EncodedString(), privKey: newSend.derRepresentation.base64EncodedString())
        updated.ratchetState.rootKey = Data(sendDerived.prefix(32)).base64EncodedString()
        updated.ratchetState.receiveChainKey = Data(receiveDerived.suffix(32)).base64EncodedString()
        updated.ratchetState.sendChainKey = Data(sendDerived.suffix(32)).base64EncodedString()
        return updated
    }

    private func skipReceiveKeys(_ state: inout E2EERatchetState, until: Int) throws {
        let gap = max(0, until - state.receiveCounter)
        guard gap <= 128 - state.skippedMessageKeys.count else { throw E2EEError.invalidEnvelope }
        while state.receiveCounter < until {
            guard let chain = state.receiveChainKey, let data = Data(base64Encoded: chain),
                  let remote = state.dhReceivingKey else { throw E2EEError.keyAgreementFailed }
            let derived = deriveMessageKeys(chainKey: data)
            state.receiveCounter += 1
            state.skippedMessageKeys["\(remote):\(state.receiveCounter)"] = derived.messageKey.base64EncodedString()
            state.receiveChainKey = derived.nextChainKey.base64EncodedString()
        }
    }

    private func generatePreKeys(userId: String, startId: Int, count: Int) throws -> [E2EEPreKeyUpload] {
        var records = try keychain.loadPreKeys(userId: userId)
        var uploads: [E2EEPreKeyUpload] = []
        for offset in 0..<count {
            let id = startId + offset
            let key = P256.KeyAgreement.PrivateKey()
            let pair = E2EEKeyPair(pubKey: key.publicKey.derRepresentation.base64EncodedString(), privKey: key.derRepresentation.base64EncodedString())
            records.removeAll { $0.id == id }
            records.append(E2EEPreKey(id: id, keyPair: pair))
            uploads.append(E2EEPreKeyUpload(keyId: id, publicKey: pair.pubKey))
        }
        try keychain.savePreKeys(records, userId: userId)
        return uploads
    }

    private func requireRegistration(userId: String) throws -> E2EERegistration {
        guard let registration = try keychain.loadRegistration(userId: userId) else {
            throw E2EEError.nativeSignalUnavailable
        }
        return registration
    }

    private func sharedSecret(_ privateKey: P256.KeyAgreement.PrivateKey, _ publicKey: P256.KeyAgreement.PublicKey) throws -> Data {
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    private func deriveMessageKeys(chainKey: Data) -> (messageKey: Data, nextChainKey: Data) {
        let salt = Data(repeating: 0, count: 32)
        return (
            hkdf(input: chainKey, salt: salt, info: Data("MessageKey".utf8), length: 32),
            hkdf(input: chainKey, salt: salt, info: Data("ChainKey".utf8), length: 32)
        )
    }

    private func hkdf(input: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = SymmetricKey(data: input)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: info, outputByteCount: length)
        return derived.withUnsafeBytes { Data($0) }
    }

    private func aesEncrypt(_ plaintext: Data, key: Data) throws -> SignalEncryptedPayload {
        let symmetricKey = SymmetricKey(data: key)
        let nonceData = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: nonce)
        let webCryptoCiphertext = sealed.ciphertext + sealed.tag
        return SignalEncryptedPayload(
            ciphertext: webCryptoCiphertext.base64EncodedString(),
            iv: nonceData.base64EncodedString(),
            tag: ""
        )
    }

    private func aesDecrypt(_ payload: SignalEncryptedPayload, key: Data) throws -> Data {
        guard let webCryptoCiphertext = Data(base64Encoded: payload.ciphertext),
              webCryptoCiphertext.count >= 16,
              let nonceData = Data(base64Encoded: payload.iv) else {
            throw E2EEError.invalidEnvelope
        }
        let ciphertext = webCryptoCiphertext.dropLast(16)
        let tag = webCryptoCiphertext.suffix(16)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(sealedBox, using: SymmetricKey(data: key))
    }
}

private struct E2EERegistration: Codable {
    let registrationId: Int
    let identityKeyPair: E2EEKeyPair
    var signedPreKey: E2EESignedPreKey
    var signingKeyPair: E2EEKeyPair? = nil
    var nextPreKeyId: Int
}

private struct E2EEKeyPair: Codable, Hashable {
    let pubKey: String
    let privKey: String
}

private struct E2EESignedPreKey: Codable {
    let id: Int
    let keyPair: E2EEKeyPair
    let signature: String
}

private struct E2EEPreKey: Codable {
    let id: Int
    let keyPair: E2EEKeyPair
}

private struct E2EESessionData: Codable {
    let localRegistrationId: Int
    let localIdentityKey: String
    let ephemeralKey: String?
    let usedOneTimePreKeyId: Int?
    let recipientSignedPreKeyId: Int?
    let recipientOneTimePreKeyId: Int?
    var ratchetState: E2EERatchetState

    private enum CodingKeys: String, CodingKey {
        case localRegistrationId, localIdentityKey, ephemeralKey, usedOneTimePreKeyId
        case recipientSignedPreKeyId, recipientOneTimePreKeyId, ratchetState
    }

    init(
        localRegistrationId: Int,
        localIdentityKey: String,
        ephemeralKey: String?,
        usedOneTimePreKeyId: Int?,
        recipientSignedPreKeyId: Int?,
        recipientOneTimePreKeyId: Int?,
        ratchetState: E2EERatchetState
    ) {
        self.localRegistrationId = localRegistrationId
        self.localIdentityKey = localIdentityKey
        self.ephemeralKey = ephemeralKey
        self.usedOneTimePreKeyId = usedOneTimePreKeyId
        self.recipientSignedPreKeyId = recipientSignedPreKeyId
        self.recipientOneTimePreKeyId = recipientOneTimePreKeyId
        self.ratchetState = ratchetState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localRegistrationId = try container.decode(Int.self, forKey: .localRegistrationId)
        localIdentityKey = try container.decode(String.self, forKey: .localIdentityKey)
        ephemeralKey = try container.decodeIfPresent(String.self, forKey: .ephemeralKey)
        usedOneTimePreKeyId = try container.decodeIfPresent(Int.self, forKey: .usedOneTimePreKeyId)
        recipientSignedPreKeyId = try container.decodeIfPresent(Int.self, forKey: .recipientSignedPreKeyId)
        recipientOneTimePreKeyId = try container.decodeIfPresent(Int.self, forKey: .recipientOneTimePreKeyId)
        ratchetState = try container.decode(E2EERatchetState.self, forKey: .ratchetState)
    }
}

private struct E2EERatchetState: Codable {
    var skippedMessageKeys: [String: String] = [:]
    var retiredRatchetKeys: [String] = []
    var dhSendingKeyPair: E2EEKeyPair
    var dhReceivingKey: String?
    var rootKey: String
    var sendChainKey: String?
    var sendCounter: Int
    var receiveChainKey: String?
    var receiveCounter: Int
    var previousSendCounter: Int
    var remoteIdentityKey: String
    var remoteRegistrationId: Int
    var protocolVersion: Int
    var sentPreKey: Bool

    private enum CodingKeys: String, CodingKey {
        case skippedMessageKeys, retiredRatchetKeys
        case dhSendingKeyPair, dhReceivingKey, rootKey, sendChainKey, sendCounter
        case receiveChainKey, receiveCounter, previousSendCounter, remoteIdentityKey
        case remoteRegistrationId, protocolVersion, sentPreKey
    }

    init(
        dhSendingKeyPair: E2EEKeyPair,
        dhReceivingKey: String?,
        rootKey: String,
        sendChainKey: String?,
        sendCounter: Int,
        receiveChainKey: String?,
        receiveCounter: Int,
        previousSendCounter: Int,
        remoteIdentityKey: String,
        remoteRegistrationId: Int,
        protocolVersion: Int,
        sentPreKey: Bool
    ) {
        self.dhSendingKeyPair = dhSendingKeyPair
        self.dhReceivingKey = dhReceivingKey
        self.rootKey = rootKey
        self.sendChainKey = sendChainKey
        self.sendCounter = sendCounter
        self.receiveChainKey = receiveChainKey
        self.receiveCounter = receiveCounter
        self.previousSendCounter = previousSendCounter
        self.remoteIdentityKey = remoteIdentityKey
        self.remoteRegistrationId = remoteRegistrationId
        self.protocolVersion = protocolVersion
        self.sentPreKey = sentPreKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skippedMessageKeys = try container.decodeIfPresent([String: String].self, forKey: .skippedMessageKeys) ?? [:]
        retiredRatchetKeys = try container.decodeIfPresent([String].self, forKey: .retiredRatchetKeys) ?? []
        dhSendingKeyPair = try container.decode(E2EEKeyPair.self, forKey: .dhSendingKeyPair)
        dhReceivingKey = try container.decodeIfPresent(String.self, forKey: .dhReceivingKey)
        rootKey = try container.decode(String.self, forKey: .rootKey)
        sendChainKey = try container.decodeIfPresent(String.self, forKey: .sendChainKey)
        sendCounter = try container.decodeIfPresent(Int.self, forKey: .sendCounter) ?? 0
        receiveChainKey = try container.decodeIfPresent(String.self, forKey: .receiveChainKey)
        receiveCounter = try container.decodeIfPresent(Int.self, forKey: .receiveCounter) ?? 0
        previousSendCounter = try container.decodeIfPresent(Int.self, forKey: .previousSendCounter) ?? 0
        remoteIdentityKey = try container.decode(String.self, forKey: .remoteIdentityKey)
        remoteRegistrationId = try container.decode(Int.self, forKey: .remoteRegistrationId)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        sentPreKey = try container.decodeIfPresent(Bool.self, forKey: .sentPreKey) ?? true
    }
}

private final class E2EEKeychainStore {
#if E2EE_REGRESSION_TESTS
    private var memory: [String: Data] = [:]
#endif
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let service = "chat.imim.e2ee"

    func removeAccountKeys(userId: String) throws {
        let matches: (String) -> Bool = {
            $0 == "registration.\(userId)" || $0 == "prekeys.\(userId)" || $0.hasPrefix("session.\(userId).")
        }
#if E2EE_REGRESSION_TESTS
        for account in Array(memory.keys) where matches(account) { memory.removeValue(forKey: account) }
#else
        let lookup: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw E2EEError.nativeSignalUnavailable
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, matches(account) else { continue }
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
            let deleted = SecItemDelete(query as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
                throw E2EEError.nativeSignalUnavailable
            }
        }
#endif
    }

    func loadRegistration(userId: String) throws -> E2EERegistration? {
        try load(E2EERegistration.self, account: "registration.\(userId)")
    }

    func saveRegistration(_ registration: E2EERegistration, userId: String) throws {
        try save(registration, account: "registration.\(userId)")
    }

    func loadPreKeys(userId: String) throws -> [E2EEPreKey] {
        try load([E2EEPreKey].self, account: "prekeys.\(userId)") ?? []
    }

    func savePreKeys(_ keys: [E2EEPreKey], userId: String) throws {
        try save(keys, account: "prekeys.\(userId)")
    }

    func removePreKey(id: Int, userId: String) throws {
        var keys = try loadPreKeys(userId: userId)
        keys.removeAll { $0.id == id }
        try savePreKeys(keys, userId: userId)
    }

    func loadSession(userId: String, peerId: String) throws -> E2EESessionData? {
        try load(E2EESessionData.self, account: "session.\(userId).\(peerId)")
    }

    func saveSession(_ session: E2EESessionData, userId: String, peerId: String) throws {
        try save(session, account: "session.\(userId).\(peerId)")
    }

    func deleteSession(userId: String, peerId: String) throws {
#if E2EE_REGRESSION_TESTS
        memory.removeValue(forKey: "session.\(userId).\(peerId)")
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session.\(userId).\(peerId)"
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw E2EEError.nativeSignalUnavailable
        }
#endif
    }

    private func load<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
#if E2EE_REGRESSION_TESTS
        guard let data = memory[account] else { return nil }
        return try decoder.decode(T.self, from: data)
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw E2EEError.nativeSignalUnavailable
        }
        return try decoder.decode(T.self, from: data)
#endif
    }

    private func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try encoder.encode(value)
#if E2EE_REGRESSION_TESTS
        memory[account] = data
#else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw E2EEError.nativeSignalUnavailable
        }

        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let createStatus = SecItemAdd(create as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw E2EEError.nativeSignalUnavailable
        }
#endif
    }
}

private actor E2EEOperationQueue {
    private var tail: Task<Void, Never>?

    // Actor isolation alone is not enough: a fetch suspends and allows reentry.
    // Chain the whole operation without blocking a thread or the UI actor.
    func perform<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        let result = Task { () throws -> T in
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        tail = Task { _ = try? await result.value }
        return try await result.value
    }
}
