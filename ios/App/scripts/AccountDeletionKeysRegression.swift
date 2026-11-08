import Foundation

// Compile with E2EE_REGRESSION_TESTS: the production manager uses its
// memory-only test store. This harness cannot delete a real Keychain item.
final class APIClient {
    static let shared = APIClient()
    private var bundles: [String: E2EEPreKeyBundle] = [:]
    func registerE2EEBundle(userId: String, bundle: E2EELocalPreKeyBundle, preKeys: [E2EEPreKeyUpload]) async throws {
        bundles[userId] = E2EEPreKeyBundle(registrationId: bundle.registrationId,
            identityKey: bundle.identityKey, signingPublicKey: bundle.signingPublicKey,
            signedPreKeyId: bundle.signedPreKeyId, signedPreKey: bundle.signedPreKey,
            signedPreKeySignature: bundle.signedPreKeySignature,
            oneTimePreKeyId: preKeys.first?.keyId, oneTimePreKey: preKeys.first?.publicKey)
    }
    func fetchE2EEBundle(userId: String) async throws -> E2EEPreKeyBundle {
        guard let bundle = bundles[userId] else { throw E2EEError.invalidRemoteBundle }
        return bundle
    }
    func fetchE2EEPreKeyCount(userId: String) async throws -> Int { 20 }
    func replenishE2EEPreKeys(userId: String, preKeys: [E2EEPreKeyUpload]) async throws {}
}

@main struct AccountDeletionKeysRegression {
    static func main() async throws {
        let manager = E2EEManager.regressionInstance()
        let a = "deletion-fixture-A-" + UUID().uuidString
        let b = "deletion-fixture-B-" + UUID().uuidString
        let original = UserDefaults.standard.string(forKey: "current_user_id")
        defer {
            UserDefaults.standard.set(original, forKey: "current_user_id")
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
        _ = try await manager.encryptText("fixture", peerId: b)
        UserDefaults.standard.set(b, forKey: "current_user_id")
        _ = try await manager.encryptText("peer fixture", peerId: a)
        let preservedBundle = try manager.regressionBundle(userId: b)
        let preservedState = try manager.regressionState(userId: b, peerId: a)
        precondition(String(data: preservedState, encoding: .utf8) != "null")
        try await manager.removeAccountKeys(userId: a)
        do { _ = try manager.regressionBundle(userId: a); fatalError("deleted registration remains") } catch {}
        let removedState = try manager.regressionState(userId: a, peerId: b)
        let currentBundle = try manager.regressionBundle(userId: b)
        let currentState = try manager.regressionState(userId: b, peerId: a)
        precondition(removedState == Data("null".utf8))
        precondition(currentBundle == preservedBundle)
        precondition(currentState == preservedState)
        UserDefaults.standard.set(a, forKey: "current_user_id")
        do { try await manager.synchronizeCurrentUser(); fatalError("deleted keys recreated") } catch {}
        print("Account key deletion regression passed: exact account scope, peer state preserved, no regeneration, memory-only fixtures")
    }
}
