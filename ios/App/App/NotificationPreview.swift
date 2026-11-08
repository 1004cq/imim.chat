import CryptoKit
import Foundation
import Security

// Independent, device-only notification keys. Never access Signal/MLS state.
struct NotificationPreviewKey: Codable {
    let keyId: String
    let publicKey: String
    var userId: String?
}

struct NotificationPreviewBox: Codable {
    let version: Int
    let keyId: String
    let recipientId: String
    let senderId: String
    let chatId: String
    let ephemeralPublicKey: String
    let nonce: String
    let ciphertext: String
    let tag: String

    var aad: Data {
        Data(["imim.notification.preview.v1", keyId, recipientId, senderId, chatId].joined(separator: "\n").utf8)
    }
}

enum NotificationPreview {
    static let group = "group.com.imim.chat"
    static let service = "chat.imim.notification-preview.v1"
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }

    static func syncPreferences(userId: String?, hidden: Bool) {
        // No auth tokens, message plaintext or private keys in shared defaults.
        defaults?.set(userId, forKey: "preview_user_id")
        defaults?.set(hidden, forKey: "preview_hidden")
    }

    static func keyID(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
    }

    private static func query(_ userId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: userId,
         // The existing App Group is also an authorized keychain access group.
         kSecAttrAccessGroup as String: group]
    }

    static func privateKey(userId: String, create: Bool = false) throws -> P256.KeyAgreement.PrivateKey {
        var lookup = query(userId)
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        // A locked/unavailable/corrupt existing key must never be overwritten.
        guard create, status == errSecItemNotFound else { throw PreviewError.unavailable }
        let key = P256.KeyAgreement.PrivateKey()
        var insert = query(userId)
        insert[kSecValueData as String] = key.rawRepresentation
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(insert as CFDictionary, nil)
        if inserted == errSecDuplicateItem { return try privateKey(userId: userId) }
        guard inserted == errSecSuccess else { throw PreviewError.unavailable }
        return key
    }

    static func registration(userId: String) throws -> NotificationPreviewKey {
        let data = try privateKey(userId: userId, create: true).publicKey.x963Representation
        return NotificationPreviewKey(keyId: keyID(data), publicKey: data.base64EncodedString(), userId: nil)
    }

    static func seal(_ text: String, to recipient: NotificationPreviewKey, senderId: String, chatId: String) throws -> NotificationPreviewBox {
        guard let recipientId = recipient.userId,
              let publicData = Data(base64Encoded: recipient.publicKey),
              keyID(publicData) == recipient.keyId,
              [recipientId, senderId, chatId].allSatisfy({ !$0.isEmpty && !$0.contains("\n") }) else { throw PreviewError.invalid }
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: publicData)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let aad = Data(["imim.notification.preview.v1", recipient.keyId, recipientId, senderId, chatId].joined(separator: "\n").utf8)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: publicKey)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: aad, outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data(shortText(text).utf8), using: key, authenticating: aad)
        return NotificationPreviewBox(version: 1, keyId: recipient.keyId, recipientId: recipientId, senderId: senderId, chatId: chatId,
            ephemeralPublicKey: ephemeral.publicKey.x963Representation.base64EncodedString(),
            nonce: Data(sealed.nonce).base64EncodedString(), ciphertext: sealed.ciphertext.base64EncodedString(), tag: sealed.tag.base64EncodedString())
    }

    static func open(_ box: NotificationPreviewBox, with key: P256.KeyAgreement.PrivateKey, userId: String, senderId: String, chatId: String) throws -> String {
        guard box.version == 1, box.recipientId == userId, box.senderId == senderId, box.chatId == chatId,
              box.keyId == keyID(key.publicKey.x963Representation),
              [userId, senderId, chatId].allSatisfy({ !$0.isEmpty && !$0.contains("\n") }),
              let pub = Data(base64Encoded: box.ephemeralPublicKey), pub.count == 65,
              let nonce = Data(base64Encoded: box.nonce), nonce.count == 12,
              let cipher = Data(base64Encoded: box.ciphertext), cipher.count <= 480,
              let tag = Data(base64Encoded: box.tag), tag.count == 16 else { throw PreviewError.invalid }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: pub)
        let secret = try key.sharedSecretFromKeyAgreement(with: peer)
        let symmetric = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: box.aad, outputByteCount: 32)
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher, tag: tag)
        let data = try AES.GCM.open(sealed, using: symmetric, authenticating: box.aad)
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw PreviewError.invalid }
        return shortText(value)
    }

    static func notificationBody(fields: [AnyHashable: Any]) -> String {
        guard defaults?.object(forKey: "preview_hidden") != nil,
              defaults?.bool(forKey: "preview_hidden") == false,
              let userId = defaults?.string(forKey: "preview_user_id"),
              let sender = fields["senderId"] as? String, let chat = fields["chatId"] as? String,
              let raw = fields["notificationPreview"], JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw), data.count <= 2048,
              let box = try? JSONDecoder().decode(NotificationPreviewBox.self, from: data),
              let key = try? privateKey(userId: userId),
              let text = try? open(box, with: key, userId: userId, senderId: sender, chatId: chat) else { return "新消息" }
        return text
    }

    static func shortText(_ text: String) -> String {
        var result = ""
        for character in text.prefix(160) {
            let candidate = result + String(character)
            if candidate.utf8.count > 480 { break }
            result = candidate
        }
        return result.isEmpty ? "新消息" : result
    }

    enum PreviewError: Error { case unavailable, invalid }
}
