import PushKit

@MainActor
final class VoIPPushManager: NSObject, @preconcurrency PKPushRegistryDelegate {
    static let shared = VoIPPushManager()
    private var registry: PKPushRegistry?

    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        PushNotificationManager.shared.handleVoIPToken(token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("[VoIP] push token invalidated: \(type.rawValue)")
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // Apple requires CallKit to be reported synchronously from this callback.
        if (payload.dictionaryPayload["type"] as? String) == "call_cancel" {
            let cancelledUUID = (payload.dictionaryPayload["uuid"] as? String).flatMap(UUID.init(uuidString:))
            CallManager.shared.reportInvalidIncomingPush {
                if let cancelledUUID {
                    CallManager.shared.end(uuid: cancelledUUID, reason: .remoteEnded, notifyRemote: false)
                }
                completion()
            }
            return
        }
        guard let descriptor = IncomingCallDescriptor(payload: payload.dictionaryPayload, requireCallId: true) else {
            CallManager.shared.reportInvalidIncomingPush(completion: completion)
            return
        }

        CallManager.shared.reportIncoming(descriptor, fromVoIPPush: true) { error in
            completion()
            guard error == nil else { return }
            Task { await self.validateAfterReport(descriptor) }
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        pushRegistry(registry, didReceiveIncomingPushWith: payload, for: type, completion: {})
    }

    private func validateAfterReport(_ descriptor: IncomingCallDescriptor) async {
        // Keep the PushKit callback short. WebSocket/IM validation happens only after CallKit is visible.
        SocketManager.shared.enterForeground()
        // The room will be joined only after CXAnswerCallAction. A later call_end/call_reject removes CallKit.
        _ = descriptor
    }
}
