import AVFoundation
import AudioToolbox
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
    private var historyTokens: [UUID: CallHistoryStore.Token] = [:]
    private var pendingAcceptedCall: IncomingCallDescriptor?
    private var silentEndRequests: Set<UUID> = []
    private let waitingFeedback = CallWaitingFeedback()
    private var feedbackObservers: [NSObjectProtocol] = []

    private override init() {
        let config = CXProviderConfiguration()
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
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            feedbackObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.waitingFeedback.refreshIncomingActivity() }
            })
        }
    }

    func start() {}

    func reportIncoming(_ descriptor: IncomingCallDescriptor, fromVoIPPush: Bool = false, recordHistory: Bool = true, completion: @escaping (Error?) -> Void) {
        let existingCall = calls[descriptor.uuid]
        // Foreground events may be deduplicated locally. Every PushKit delivery must
        // still reach CallKit, even when the matching WebSocket invite arrived first.
        guard existingCall == nil || fromVoIPPush else {
            completion(nil)
            return
        }
        if existingCall == nil {
            calls[descriptor.uuid] = descriptor
            if recordHistory {
                historyTokens[descriptor.uuid] = CallHistoryStore.shared.begin(callID: descriptor.callId,
                    peerID: descriptor.peerId, mediaKind: descriptor.isVideo ? "video" : "audio", isIncoming: true)
            }
            // Only foreground haptics are app-owned. CallKit owns the ringtone
            // and background/locked alerts, including the user's system settings.
            waitingFeedback.startIncoming(id: descriptor.uuid.uuidString)
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
                    CallHistoryStore.shared.finish(self?.historyTokens.removeValue(forKey: descriptor.uuid), reason: .failed)
                    self?.calls.removeValue(forKey: descriptor.uuid)
                    self?.waitingFeedback.stop(id: descriptor.uuid.uuidString)
                }
                #if DEBUG
                print("[CallAudio] event=incoming_report success=\(error == nil) foreground=\(UIApplication.shared.applicationState == .active) customRingtone=\(Bundle.main.url(forResource: "call_incoming", withExtension: "caf") != nil)")
                #endif
                completion(error)
            }
        }
    }

    func reportInvalidIncomingPush(completion: @escaping () -> Void) {
        let descriptor = IncomingCallDescriptor(
            uuid: UUID(), callId: "invalid-\(UUID().uuidString)", peerId: "unknown", peerName: "来电", peerAvatar: nil, roomId: "", isVideo: false
        )
        reportIncoming(descriptor, recordHistory: false) { [weak self] _ in
            self?.end(uuid: descriptor.uuid, reason: .failed, notifyRemote: false)
            completion()
        }
    }

    func accept(uuid: UUID) {
        waitingFeedback.stop(id: uuid.uuidString)
        controller.request(CXTransaction(action: CXAnswerCallAction(call: uuid))) { error in
            if let error { print("[CallKit] accept request failed: \(error.localizedDescription)") }
        }
    }

    func end(uuid: UUID, reason: CXCallEndedReason = .remoteEnded, notifyRemote: Bool = true) {
        waitingFeedback.stop(id: uuid.uuidString)
        let historyReason: CallHistoryStore.EndReason
        switch reason {
        case .failed: historyReason = .failed
        case .unanswered: historyReason = .unanswered
        case .declinedElsewhere: historyReason = .declined
        default: historyReason = notifyRemote ? .endedLocally : .endedRemotely
        }
        CallHistoryStore.shared.finish(historyTokens.removeValue(forKey: uuid), reason: historyReason)
        if !notifyRemote { silentEndRequests.insert(uuid) }
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
            if let error { print("[CallKit] end request failed: \(error.localizedDescription)") }
        }
    }

    func endCall(forPeerId peerId: String, callId: String? = nil, reason: CXCallEndedReason) {
        guard let uuid = calls.first(where: {
            guard $0.value.peerId == peerId else { return false }
            guard let callId, !callId.isEmpty else { return true }
            return $0.value.callId == callId || $0.key.uuidString == callId
        })?.key else { return }
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
        waitingFeedback.stop()
        for token in historyTokens.values { CallHistoryStore.shared.finish(token, reason: .failed) }
        historyTokens.removeAll()
        calls.removeAll()
        pendingAcceptedCall = nil
        TRTCManager.shared.handleCallKitAudioSessionDeactivated()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        guard TRTCManager.shared.prepareForCallKitAudioActivation(callType: action.isVideo ? .video : .audio) else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let descriptor = calls[action.callUUID] else { action.fail(); return }
        waitingFeedback.stop(id: action.callUUID.uuidString)
        // Delegate callbacks use queue .main. Configure synchronously before
        // fulfilling; a queued Task can run after didActivate and erase it.
        guard TRTCManager.shared.prepareForCallKitAudioActivation(callType: descriptor.isVideo ? .video : .audio) else {
            action.fail()
            return
        }
        pendingAcceptedCall = descriptor
        action.fulfill()
        NotificationCenter.default.post(name: .cqimCallAnsweredFromSystem, object: nil, userInfo: descriptor.userInfo)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        waitingFeedback.stop(id: action.callUUID.uuidString)
        CallHistoryStore.shared.finish(historyTokens.removeValue(forKey: action.callUUID), reason: .endedLocally)
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
        TRTCManager.shared.handleCallKitAudioSessionActivated(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        TRTCManager.shared.handleCallKitAudioSessionDeactivated()
    }
}

// MARK: - Call waiting feedback

/// Main-actor owned, per-call feedback. No AudioSession category, microphone,
/// route or activation changes: TRTC/CallKit remain the audio-session owners.
@MainActor
final class CallWaitingFeedback {
    struct Playback {
        let play: @MainActor () -> Void
        let stop: @MainActor () -> Void
    }
    private enum Mode: Equatable { case incoming(String), outgoing(String) }
    private var mode: Mode?
    private var playback: Playback?
    private var hapticTask: Task<Void, Never>?
    private var generation = UUID()
    private let makePlayback: @MainActor () -> Playback?
    private let vibrate: @MainActor () -> Void
    private let isActive: @MainActor () -> Bool
    private let interval: Duration

    init(makePlayback: @escaping @MainActor () -> Playback? = CallWaitingFeedback.bundledPlayback,
         vibrate: @escaping @MainActor () -> Void = { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) },
         isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         interval: Duration = .milliseconds(2400)) {
        self.makePlayback = makePlayback
        self.vibrate = vibrate
        self.isActive = isActive
        self.interval = interval
    }

    deinit { hapticTask?.cancel() }

    func startOutgoing(id: String) {
        if mode != .outgoing(id) {
            stop()
            mode = .outgoing(id)
            playback = makePlayback()
        }
        playback?.play() // Reuse the player; recover if SDK audio activation paused it.
    }

    func startIncoming(id: String) {
        if mode != .incoming(id) {
            stop()
            mode = .incoming(id)
        }
        refreshIncomingActivity()
    }

    func refreshIncomingActivity() {
        guard case .incoming = mode else { return }
        guard isActive() else { cancelHaptics(); return }
        guard hapticTask == nil else { return }
        let generation = generation
        vibrate()
        let interval = interval
        hapticTask = Task { @concurrent [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                let keepGoing = await self.pulse(generation: generation)
                if !keepGoing { return }
            }
        }
    }

    private func pulse(generation: UUID) -> Bool {
        guard self.generation == generation, case .incoming = mode else { return false }
        guard isActive() else { cancelHaptics(); return false }
        vibrate()
        return true
    }

    func stop(id: String? = nil) {
        if let id {
            guard mode == .incoming(id) || mode == .outgoing(id) else { return }
        }
        mode = nil
        cancelHaptics()
        playback?.stop()
        playback = nil
    }

    private func cancelHaptics() {
        generation = UUID()
        hapticTask?.cancel()
        hapticTask = nil
    }

    private static func bundledPlayback() -> Playback? {
        // Existing valid, bundled CAF; ringtone.mp3 is not a playable source.
        guard let url = Bundle.main.url(forResource: "call_incoming", withExtension: "caf"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.numberOfLoops = -1
        player.volume = 0.45
        player.prepareToPlay()
        return Playback(play: { if !player.isPlaying { player.play() } }, stop: { player.stop() })
    }
}

// MARK: - End call waiting feedback
