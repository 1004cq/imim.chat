import Foundation

// E2EE_REGRESSION_TESTS makes the production Keychain store memory-only.
// This API is synthetic and must never contact a deployed server.
final class APIClient {
    static let shared = APIClient()
    var bundles: [String: E2EEPreKeyBundle] = [:]
    var calls = 0
    func registerE2EEBundle(userId: String, bundle: E2EELocalPreKeyBundle, preKeys: [E2EEPreKeyUpload]) async throws {
        calls += 1
        bundles[userId] = E2EEPreKeyBundle(registrationId: bundle.registrationId,
            identityKey: bundle.identityKey, signingPublicKey: bundle.signingPublicKey,
            signedPreKeyId: bundle.signedPreKeyId, signedPreKey: bundle.signedPreKey,
            signedPreKeySignature: bundle.signedPreKeySignature,
            oneTimePreKeyId: preKeys.first?.keyId, oneTimePreKey: preKeys.first?.publicKey)
    }
    func fetchE2EEBundle(userId: String) async throws -> E2EEPreKeyBundle {
        calls += 1
        guard let bundle = bundles[userId] else { throw E2EEError.invalidRemoteBundle }
        return bundle
    }
    func fetchE2EEPreKeyCount(userId: String) async throws -> Int { calls += 1; return 20 }
    func replenishE2EEPreKeys(userId: String, preKeys: [E2EEPreKeyUpload]) async throws { calls += 1 }
}

@main struct E2EESecurityRegression {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label); checks += 1
        }
        for vector in WebSafetyVectors.values {
            let local = Data(base64Encoded: vector.local)!, remote = Data(base64Encoded: vector.remote)!
            check(IMIMSafetyCode.number(local: local, remote: remote) == vector.number, "matches actual Web 520-digit function")
            check(IMIMSafetyCode.number(local: remote, remote: local) == vector.number, "symmetric code")
            check(IMIMSafetyCode.fingerprint(local) == vector.fingerprint, "matches Web fingerprint")
            check(vector.number.split(separator: " ").count == 52, "52 groups")
        }
        let manager = E2EEManager.regressionInstance()
        let a = "security-fixture-A-" + UUID().uuidString, b = "security-fixture-B-" + UUID().uuidString
        let oldOwner = UserDefaults.standard.string(forKey: "current_user_id")
        defer {
            UserDefaults.standard.set(oldOwner, forKey: "current_user_id")
            for id in [a, b] {
                UserDefaults.standard.removeObject(forKey: "e2ee_bundle_registration_id_" + id)
                UserDefaults.standard.removeObject(forKey: "e2ee_prekey_pool_schema_version_" + id)
            }
        }
        for id in [a, b] {
            UserDefaults.standard.set(id, forKey: "current_user_id")
            try await manager.synchronizeCurrentUser()
        }
        UserDefaults.standard.set(a, forKey: "current_user_id")
        do { _ = try await manager.peerSecurityInfo(ownerID: a, peerID: b); preconditionFailure("phantom session") }
        catch E2EESecurityInfoError.noSession { checks += 1 }
        let envelope = try await manager.encryptText("synthetic security test", peerId: b)
        let stateA = try manager.regressionState(userId: a, peerId: b)
        let callsBeforeRead = APIClient.shared.calls
        let first = try await manager.peerSecurityInfo(ownerID: a, peerID: b)
        check(first.verifiedAt == nil && !first.identityChanged, "not verified on open")
        check(first.sendCounter == 1, "real current-chain counter")
        check(try manager.regressionState(userId: a, peerId: b) == stateA, "read leaves ratchet byte-for-byte unchanged")
        check(APIClient.shared.calls == callsBeforeRead, "read performs no API calls or prekey consumption")
        try await manager.setPeerVerified(ownerID: a, peerID: b, expectedBinding: first.binding, verified: true)
        let verified = try await manager.peerSecurityInfo(ownerID: a, peerID: b)
        check(verified.verifiedAt != nil, "explicit verification persists locally")
        check(try manager.regressionState(userId: a, peerId: b) == stateA, "verification does not change ratchet")

        UserDefaults.standard.set(b, forKey: "current_user_id")
        let decoded = try await manager.decryptText(envelope, peerId: a)
        check(decoded == "synthetic security test", "normal decrypt unaffected")
        let reverse = try await manager.peerSecurityInfo(ownerID: b, peerID: a)
        check(reverse.safetyNumber == first.safetyNumber, "actual opposite sessions agree")
        check(reverse.verifiedAt == nil, "verification does not mark peer's account")
        check(reverse.matchesQR(first.qrPayload), "native QR cross-direction matches")
        check(!first.matchesQR(first.qrPayload), "own QR is not peer verification")
        var webQR = try JSONSerialization.jsonObject(with: Data(first.qrPayload.utf8)) as! [String: Any]
        webQR.removeValue(forKey: "ownerId")
        let webPayload = String(decoding: try JSONSerialization.data(withJSONObject: webQR), as: UTF8.self)
        check(reverse.matchesQR(webPayload), "deployed Web v1 fields supported")
        for (key, bad) in [("v", 2 as Any), ("type", "other" as Any), ("peerId", "wrong" as Any),
                           ("ownerId", "wrong" as Any), ("safetyNumber", "0" as Any), ("localKey", "00" as Any)] {
            var tampered = webQR; tampered[key] = bad
            let value = String(decoding: try JSONSerialization.data(withJSONObject: tampered), as: UTF8.self)
            check(!reverse.matchesQR(value), "rejects tampered QR field")
        }
        check(!reverse.matchesQR(String(repeating: "x", count: 9_000)), "bounded input")
        check(!reverse.matchesQR("https://example.invalid"), "no URL/deep-link execution")
        do { _ = try await manager.peerSecurityInfo(ownerID: a, peerID: b); preconditionFailure("cross account") }
        catch E2EESecurityInfoError.accountChanged { checks += 1 }

        // Simulate a second device with fresh identity keys, all memory-only.
        let oldBundleB = APIClient.shared.bundles[b]!
        let secondDevice = E2EEManager.regressionInstance()
        try await secondDevice.synchronizeCurrentUser()
        UserDefaults.standard.set(a, forKey: "current_user_id")
        try await manager.resetSession(with: b)
        _ = try await manager.encryptText("synthetic rotated identity", peerId: b)
        do {
            try await manager.setPeerVerified(ownerID: a, peerID: b, expectedBinding: first.binding, verified: true)
            preconditionFailure("stale confirmation accepted")
        } catch E2EESecurityInfoError.identityChanged { checks += 1 }
        let changed = try await manager.peerSecurityInfo(ownerID: a, peerID: b)
        check(changed.binding != first.binding && changed.safetyNumber != first.safetyNumber, "full keys bind code and verification")
        check(changed.verifiedAt == nil && changed.identityChanged, "key rotation invalidates marker")
        APIClient.shared.bundles[b] = oldBundleB
        try await manager.resetSession(with: b)
        _ = try await manager.encryptText("synthetic restored key", peerId: b)
        let restored = try await manager.peerSecurityInfo(ownerID: a, peerID: b)
        check(restored.binding == first.binding && restored.verifiedAt == nil && restored.identityChanged, "old key cannot revive invalidated verification")
        try await manager.setPeerVerified(ownerID: a, peerID: b, expectedBinding: restored.binding, verified: true)
        try await manager.setPeerVerified(ownerID: a, peerID: b, expectedBinding: restored.binding, verified: false)
        let removed = try await manager.peerSecurityInfo(ownerID: a, peerID: b)
        check(removed.verifiedAt == nil && !removed.identityChanged, "remove verification")
        try await manager.removeAccountKeys(userId: a)
        check(try manager.regressionVerification(userId: a, peerId: b) == Data("null".utf8), "account deletion removes verification metadata")
        checks += try await checkInitiationLoss()
        print("PASS: \(checks) production safety-code/session/QR/verification assertions; memory-only keys and synthetic API, no live data")
    }
    static func checkInitiationLoss() async throws -> Int {
        let manager = E2EEManager.regressionInstance(), api = APIClient.shared
        let a = "init-loss-a-" + UUID().uuidString, b = "init-loss-b-" + UUID().uuidString
        let oldOwner = UserDefaults.standard.string(forKey: "current_user_id")
        defer {
            UserDefaults.standard.set(oldOwner, forKey: "current_user_id")
            for owner in [a, b] {
                for prefix in ["e2ee_bundle_registration_id_", "e2ee_prekey_pool_schema_version_"] {
                    UserDefaults.standard.removeObject(forKey: prefix + owner)
                }
                api.bundles.removeValue(forKey: owner)
            }
        }
        for owner in [a, b] {
            UserDefaults.standard.set(owner, forKey: "current_user_id")
            try await manager.synchronizeCurrentUser()
        }
        UserDefaults.standard.set(a, forKey: "current_user_id")
        let first = try await manager.encryptText("synthetic withheld first", peerId: b)
        let second = try await manager.encryptText("synthetic delivered second", peerId: b)
        let decoder = JSONDecoder()
        let firstEnvelope = try decoder.decode(SignalEnvelope.self, from: Data(first.utf8))
        let secondEnvelope = try decoder.decode(SignalEnvelope.self, from: Data(second.utf8))
        precondition(firstEnvelope.type == "prekey" && secondEnvelope.type == "prekey")
        precondition(firstEnvelope.senderEphemeralKey == secondEnvelope.senderEphemeralKey)
        precondition(firstEnvelope.recipientSignedPreKeyId == secondEnvelope.recipientSignedPreKeyId)
        precondition(firstEnvelope.recipientOneTimePreKeyId == secondEnvelope.recipientOneTimePreKeyId)
        UserDefaults.standard.set(b, forKey: "current_user_id")
        let beforeRead = try manager.regressionState(userId: b, peerId: a)
        let preKeysBeforeRead = manager.diagnosticsForCurrentUser()!.availablePreKeyCount
        let readOnly = try await manager.decryptText(second, peerId: a, persistSession: false)
        precondition(readOnly == "synthetic delivered second")
        let afterRead = try manager.regressionState(userId: b, peerId: a)
        precondition(beforeRead == afterRead)
        precondition(manager.diagnosticsForCurrentUser()!.availablePreKeyCount == preKeysBeforeRead)
        let deliveredSecond = try await manager.decryptText(second, peerId: a)
        precondition(deliveredSecond == "synthetic delivered second")
        let beforeSkippedRead = try manager.regressionState(userId: b, peerId: a)
        let skippedRead = try await manager.decryptText(first, peerId: a, persistSession: false)
        precondition(skippedRead == "synthetic withheld first")
        let afterSkippedRead = try manager.regressionState(userId: b, peerId: a)
        precondition(beforeSkippedRead == afterSkippedRead)
        let delayedFirst = try await manager.decryptText(first, peerId: a)
        precondition(delayedFirst == "synthetic withheld first")
        let reply = try await manager.encryptText("synthetic authenticated reply", peerId: a)
        UserDefaults.standard.set(a, forKey: "current_user_id")
        var invalid = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as! [String: Any]
        var ciphertext = invalid["ciphertext"] as! [String: Any]
        var bytes = Data(base64Encoded: ciphertext["ciphertext"] as! String)!
        bytes[0] ^= 1
        ciphertext["ciphertext"] = bytes.base64EncodedString(); invalid["ciphertext"] = ciphertext
        let tampered = String(decoding: try JSONSerialization.data(withJSONObject: invalid), as: UTF8.self)
        do { _ = try await manager.decryptText(tampered, peerId: b); preconditionFailure("Unauthenticated reply accepted") }
        catch { }
        let pending = try await manager.encryptText("synthetic still unconfirmed", peerId: b)
        let pendingEnvelope = try decoder.decode(SignalEnvelope.self, from: Data(pending.utf8))
        precondition(pendingEnvelope.type == "prekey")
        let authenticatedReply = try await manager.decryptText(reply, peerId: b)
        precondition(authenticatedReply == "synthetic authenticated reply")
        let confirmed = try await manager.encryptText("synthetic confirmed", peerId: b)
        let confirmedEnvelope = try decoder.decode(SignalEnvelope.self, from: Data(confirmed.utf8))
        precondition(confirmedEnvelope.type == "message")
        UserDefaults.standard.set(b, forKey: "current_user_id")
        let confirmedReply = try await manager.decryptText(confirmed, peerId: a)
        precondition(confirmedReply == "synthetic confirmed")
        print("PASS: lost first envelope, delayed first delivery, same bootstrap keys, read-only retry keeps live state/prekeys, authenticated confirmation and tampered-reply rejection")
        return 16
    }

}
