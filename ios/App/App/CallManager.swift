import AVFoundation
import CallKit
import UIKit

struct IncomingCallDescriptor: Equatable {
    let uuid: UUID
    let callId: String
    let peerId: String
    let peerName: String
    let peerAvatar: String?
    let roomId: String
    let isVideo: Bool

    init(uuid: UUID, callId: String, peerId: String, peerName: String, peerAvatar: String?, roomId: String, isVideo: Bool) {
        self.uuid = uuid
        self.callId = callId
        self.peerId = peerId
        self.peerName = peerName
        self.peerAvatar = peerAvatar
        self.roomId = roomId
        self.isVideo = isVideo
    }

    var userInfo: [String: Any] {
        [
            "uuid": uuid.uuidString,
            "callId": callId,
            "from": peerId,
            "roomId": roomId,
            "callType": isVideo ? "video" : "audio",
            "callerName": peerName,
            "callerAvatar": peerAvatar ?? ""
        ]
    }

    init?(payload: [AnyHashable: Any], requireCallId: Bool) {
        let string = { (keys: [String]) -> String? in
            keys.lazy.compactMap { payload[$0] as? String }.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let peerId = string(["fromUserId", "caller_id", "from"]), !peerId.isEmpty else { return nil }
        let rawCallId = string(["callId", "call_id"])
        guard !requireCallId || (rawCallId?.isEmpty == false) else { return nil }
        let callId = rawCallId?.isEmpty == false ? rawCallId! : "ws-\(peerId)-\(string(["roomId", "room_id"]) ?? UUID().uuidString)"
        let rawUUID = string(["uuid"])
        let uuid = rawUUID.flatMap(UUID.init(uuidString:)) ?? Self.stableUUID(from: callId)
        let type = string(["callType", "call_type"])?.lowercased()
        let isVideo: Bool
        if let value = payload["isVideo"] as? Bool {
            isVideo = value
        } else if let value = payload["isVideo"] as? String {
            isVideo = value.lowercased() == "true"
        } else {
            isVideo = type == "video"
        }

        self.uuid = uuid
        self.callId = callId
        self.peerId = peerId
        self.peerName = string(["fromName", "caller_name", "callerName"])?.nonEmpty ?? "来电"
        self.peerAvatar = string(["fromAvatar", "caller_avatar", "callerAvatar"])?.nonEmpty
        self.roomId = string(["roomId", "room_id"])?.nonEmpty ?? "room-\(callId)"
        self.isVideo = isVideo
    }

    private static func stableUUID(from value: String) -> UUID {
        let bytes = Array(value.utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let high = hash.bigEndian
        let low = (hash &* 0x9e3779b97f4a7c15).bigEndian
        let h = withUnsafeBytes(of: high) { Array($0) }
        let l = withUnsafeBytes(of: low) { Array($0) }
        let b = h + l
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}

@MainActor
final class CallManager: NSObject, @preconcurrency CXProviderDelegate {
    static let shared = CallManager()

    private let provider: CXProvider
    private let controller = CXCallController()
    private var calls: [UUID: IncomingCallDescriptor] = [:]
    private var pendingAcceptedCall: IncomingCallDescriptor?
    private var silentEndRequests: Set<UUID> = []

    private override init() {
        let config = CXProviderConfiguration(localizedName: "imm")
        config.ringtoneSound = "call_incoming.caf"
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        if let icon = UIImage(named: "CallKitIcon") ?? UIImage(named: "AppIcon") {
            config.iconTemplateImageData = icon.pngData()
        }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func start() {}

    func reportIncoming(_ descriptor: IncomingCallDescriptor, fromVoIPPush: Bool = false, completion: @escaping (Error?) -> Void) {
        let existingCall = calls[descriptor.uuid]
        // Foreground events may be deduplicated locally. Every PushKit delivery must
        // still reach CallKit, even when the matching WebSocket invite arrived first.
        guard existingCall == nil || fromVoIPPush else {
            completion(nil)
            return
        }
        if existingCall == nil {
            calls[descriptor.uuid] = descriptor
        }
        let reportedCall = existingCall ?? descriptor
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: reportedCall.peerId)
        update.localizedCallerName = reportedCall.peerName
        update.hasVideo = reportedCall.isVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: descriptor.uuid, update: update) { [weak self] error in
            MainActor.assumeIsolated {
                // A duplicate UUID is rejected by CallKit without ending the original
                // call. Only a failed first report owns the provisional state to remove.
                if error != nil, existingCall == nil {
                    self?.calls.removeValue(forKey: descriptor.uuid)
                }
                completion(error)
            }
        }
    }

    func reportInvalidIncomingPush(completion: @escaping () -> Void) {
        let descriptor = IncomingCallDescriptor(
            uuid: UUID(), callId: "invalid-\(UUID().uuidString)", peerId: "unknown", peerName: "来电", peerAvatar: nil, roomId: "", isVideo: false
        )
        reportIncoming(descriptor) { [weak self] _ in
            self?.end(uuid: descriptor.uuid, reason: .failed, notifyRemote: false)
            completion()
        }
    }

    func accept(uuid: UUID) {
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
            if let error { print("[CallKit] accept request failed: \(error.localizedDescription)") }
        }
    }

    func end(uuid: UUID, reason: CXCallEndedReason = .remoteEnded, notifyRemote: Bool = true) {
        if !notifyRemote { silentEndRequests.insert(uuid) }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
            if let error { print("[CallKit] end request failed: \(error.localizedDescription)") }
        }
    }

    func endCall(forPeerId peerId: String, reason: CXCallEndedReason) {
        guard let uuid = calls.first(where: { $0.value.peerId == peerId })?.key else { return }
        end(uuid: uuid, reason: reason, notifyRemote: false)
    }

    func requestStartOutgoing(handle: String, isVideo: Bool) {
        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = isVideo
        controller.request(CXTransaction(action: action)) { error in
            if let error { print("[CallKit] outgoing request failed: \(error.localizedDescription)") }
        }
    }

    func takePendingAcceptedCall() -> IncomingCallDescriptor? {
        defer { pendingAcceptedCall = nil }
        return pendingAcceptedCall
    }

    func providerDidReset(_ provider: CXProvider) {
        calls.removeAll()
        pendingAcceptedCall = nil
        Task { @MainActor in TRTCManager.shared.handleCallKitAudioSessionDeactivated() }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let descriptor = calls[action.callUUID] else { action.fail(); return }
        pendingAcceptedCall = descriptor
        Task { @MainActor in TRTCManager.shared.prepareForCallKitAudioActivation() }
        action.fulfill()
        NotificationCenter.default.post(name: .cqimCallAnsweredFromSystem, object: nil, userInfo: descriptor.userInfo)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let descriptor = calls.removeValue(forKey: action.callUUID)
        let notifyRemote = silentEndRequests.remove(action.callUUID) == nil
        if let descriptor {
            if notifyRemote { SocketManager.shared.sendCallEnd(to: descriptor.peerId, callId: descriptor.callId) }
            NotificationCenter.default.post(name: .cqimCallEnded, object: nil, userInfo: descriptor.userInfo)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in TRTCManager.shared.setMuted(action.isMuted) }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in TRTCManager.shared.handleCallKitAudioSessionActivated(audioSession) }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in TRTCManager.shared.handleCallKitAudioSessionDeactivated() }
    }
}
