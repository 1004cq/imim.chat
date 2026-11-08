import CryptoKit
import Foundation
import Security

/// Keys stay on the device. This metadata is carried inside the Signal
/// envelope, never in multipart fields, APNs or a SwiftData schema.
struct EncryptedMediaMetadata: Codable, Sendable, Hashable {
    let version: Int
    let originalType: String
    let fileName: String
    let mimeType: String
    let byteSize: Int
    let mediaKey: String
    let mediaIV: String
    let mediaTag: String
    let duration: Double?
    let waveform: [Double]?

    var displayText: String {
        switch originalType {
        case "image": return "[图片]"
        case "voice": return "[语音消息]"
        case "video": return "[视频]"
        default: return fileName
        }
    }

    func decrypt(_ data: Data) throws -> Data {
        guard version == 1, byteSize > 0, byteSize <= 200 * 1_024 * 1_024,
              let key = Data(base64Encoded: mediaKey), key.count == 32,
              let iv = Data(base64Encoded: mediaIV), iv.count == 12,
              let tag = Data(base64Encoded: mediaTag), tag.count == 16,
              data.count == byteSize + 16, Data(data.suffix(16)) == tag else {
            throw EncryptedMediaError.invalidAttachment
        }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                       ciphertext: data.dropLast(16), tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }
}

enum EncryptedMediaError: LocalizedError {
    case invalidAttachment, missingMetadata, invalidURL, keyStorageFailed
    var errorDescription: String? {
        switch self {
        case .invalidAttachment: return "附件校验失败，已阻止播放"
        case .missingMetadata: return "附件密钥不可用，请让发送者重新发送"
        case .invalidURL: return "附件地址无效"
        case .keyStorageFailed: return "无法安全保存附件密钥"
        }
    }
}

/// Serializes cache writes/decryption away from the UI, while coalescing
/// concurrent requests for the same account/message into one download.
actor EncryptedMediaStore {
    static let shared = EncryptedMediaStore()
    private var inFlight: [String: Task<URL, Error>] = [:]
    private let service = "chat.imim.encrypted-media"
    private var deletedAccounts = Set<String>()

    func remove(owner: String, messageIDs: [String]) {
        deletedAccounts.insert(owner)
        for id in messageIDs {
            if let record = try? stored(owner: owner, messageID: id),
               let file = try? cacheURL(owner: owner, messageID: id, metadata: record.metadata) {
                inFlight[file.lastPathComponent]?.cancel()
                inFlight[file.lastPathComponent] = nil
                try? FileManager.default.removeItem(at: file)
            }
            SecItemDelete(keyQuery(owner: owner, messageID: id) as CFDictionary)
        }
    }

    func metadata(owner: String, messageID: String) throws -> EncryptedMediaMetadata {
        try stored(owner: owner, messageID: messageID).metadata
    }

    func remember(owner: String, messageID: String, metadata: EncryptedMediaMetadata, remoteURL: String?) throws {
        guard !deletedAccounts.contains(owner) else { throw EncryptedMediaError.keyStorageFailed }
        let record = Record(metadata: metadata, remoteURL: remoteURL)
        let data = try JSONEncoder().encode(record)
        let query = keyQuery(owner: owner, messageID: messageID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw EncryptedMediaError.keyStorageFailed
            }
        } else if status != errSecSuccess { throw EncryptedMediaError.keyStorageFailed }
    }

    func saveOutgoing(owner: String, messageID: String, metadata: EncryptedMediaMetadata,
                      remoteURL: String?, plaintext: Data) throws -> URL {
        try remember(owner: owner, messageID: messageID, metadata: metadata, remoteURL: remoteURL)
        let target = try cacheURL(owner: owner, messageID: messageID, metadata: metadata)
        try write(plaintext, to: target)
        return target
    }

    func localFile(owner: String, messageID: String, origin: URL) async throws -> URL {
        guard !deletedAccounts.contains(owner) else { throw EncryptedMediaError.missingMetadata }
        let record = try stored(owner: owner, messageID: messageID)
        let target = try cacheURL(owner: owner, messageID: messageID, metadata: record.metadata)
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber,
           size.intValue == record.metadata.byteSize { return target }
        let identity = target.lastPathComponent
        if let task = inFlight[identity] { return try await task.value }
        let source = try Self.sourceURL(record.remoteURL, origin: origin)
        // This task inherits this background actor, not MainActor. Sharing its
        // lifetime lets one cancelled view leave other callers' download intact.
        let task = Task<URL, Error> {
            var request = URLRequest(url: source)
            request.timeoutInterval = 180
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let finalURL = http.url,
                  (try? Self.sourceURL(finalURL.absoluteString, origin: origin)) != nil,
                  let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
                  size.intValue == record.metadata.byteSize + 16 else {
                throw EncryptedMediaError.invalidAttachment
            }
            let plaintext = try record.metadata.decrypt(Data(contentsOf: temporary, options: .mappedIfSafe))
            try Task.checkCancellation()
            try self.write(plaintext, to: target)
            return target
        }
        inFlight[identity] = task
        defer { inFlight[identity] = nil }
        return try await task.value
    }

    static func sourceURL(_ value: String?, origin: URL) throws -> URL {
        guard let value, let url = URL(string: value, relativeTo: origin)?.absoluteURL,
              url.scheme == "https", url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.path.hasPrefix("/api/media/") else {
            throw EncryptedMediaError.invalidURL
        }
        return url
    }

    private struct Record: Codable { let metadata: EncryptedMediaMetadata; let remoteURL: String? }

    private func keyQuery(owner: String, messageID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: digest(owner + ":" + messageID)]
    }

    private func stored(owner: String, messageID: String) throws -> Record {
        var query = keyQuery(owner: owner, messageID: messageID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { throw EncryptedMediaError.missingMetadata }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private func cacheURL(owner: String, messageID: String, metadata: EncryptedMediaMetadata) throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("EncryptedMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var protectedFolder = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedFolder.setResourceValues(values)
        let ext = URL(fileURLWithPath: metadata.fileName).pathExtension
        let safeExt = ext.count <= 12 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? ext : "bin"
        return folder.appendingPathComponent(digest(owner + ":" + messageID + ":" + metadata.mediaKey + ":" + metadata.mediaIV))
            .appendingPathExtension(safeExt)
    }

    private func write(_ data: Data, to target: URL) throws {
        #if os(iOS)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: target, options: .atomic)
        #endif
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
