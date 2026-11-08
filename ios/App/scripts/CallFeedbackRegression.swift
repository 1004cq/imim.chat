// Native controller is real; sound/vibration closures are silent counters.
// Signaling variant compiles the real ViewModel with fixture transport/SDK.
@MainActor final class FeedbackProbe {
    var players = 0, plays = 0, stops = 0, pulses = 0
    var active = true, playing = false
    func feedback() -> CallWaitingFeedback {
        CallWaitingFeedback(makePlayback: { [self] in
            players += 1
            return .init(play: { [self] in
                if !playing { playing = true; plays += 1 }
            }, stop: { [self] in playing = false; stops += 1 })
        }, vibrate: { [self] in pulses += 1 }, isActive: { [self] in active }, interval: .milliseconds(20))
    }
}
#if !CONTROLLER_ONLY
// History wiring probe. The separate harness runs the real SwiftData store.
@MainActor final class CallHistoryStore {
    static let shared = CallHistoryStore()
    typealias Token = String
    enum EndReason { case endedLocally, endedRemotely, declined, unanswered, failed }
    var connectedIDs: [String] = []
    var endings: [(String, EndReason)] = []
    func begin(callID: String, peerID: String, mediaKind: String, isIncoming: Bool, chatID: String? = nil) -> String? { callID }
    func connected(_ token: String?) { if let token { connectedIDs.append(token) } }
    func finish(_ token: String?, reason: EndReason) { if let token { endings.append((token, reason)) } }
}
enum TRTCConnectionState: Equatable {
    case idle, connected, failed(String)
    var title: String { "fixture" }
}
struct TRTCRemoteParticipant { let id: String }
@MainActor final class TRTCManager: ObservableObject {
    static let shared = TRTCManager()
    @Published var connectionState: TRTCConnectionState = .idle
    @Published var remoteParticipants: [TRTCRemoteParticipant] = []
    var joins = 0, exits = 0
    func enterRoom(roomId: String, credentials: Int, callType: VideoCallType) async {
        joins += 1; remoteParticipants = []; connectionState = .connected
    }
    func exitRoom() { exits += 1; connectionState = .idle; remoteParticipants = [] }
    func toggleMute() {}
    func toggleCamera() {}
    func toggleSpeaker() {}
    func switchCamera() {}
    func toggleScreenSharing() {}
}
@MainActor final class APIClient {
    static let shared = APIClient()
    var shouldFail = false
    var paused = false
    var pending: CheckedContinuation<Int, Error>?
    func fetchTRTCUserSig() async throws -> Int {
        if shouldFail { throw URLError(.timedOut) }
        if paused { return try await withCheckedThrowingContinuation { pending = $0 } }
        return 1
    }
    func resume() { paused = false; pending?.resume(returning: 1); pending = nil }
}
@MainActor final class SocketManager {
    static let shared = SocketManager()
    var invites = 0
    func sendCallInvite(to: String, roomId: String, callType: String, callerName: String, callerAvatar: String?, callId: String) { invites += 1 }
    func sendCallAccept(to: String) {}
    func sendCallReject(to: String, callId: String) {}
    func sendCallEnd(to: String, callId: String) {}
}
@MainActor final class CallManager {
    static let shared = CallManager()
    var endings: [(UUID, Bool)] = []
    func end(uuid: UUID, reason: CXCallEndedReason, notifyRemote: Bool = true) { endings.append((uuid, notifyRemote)) }
}
extension Notification.Name {
    static let cqimCallAccepted = Notification.Name("FixtureAccepted")
    static let cqimCallRejected = Notification.Name("FixtureRejected")
    static let cqimCallEnded = Notification.Name("FixtureEnded")
}
#endif
@main @MainActor
struct CallFeedbackRegression {
    static var checks = 0
    static func check(_ value: Bool, _ note: String) {
        if !value { print("FAIL: " + note); fflush(stdout) }
        precondition(value, note); checks += 1
    }
    static func settle(_ duration: Duration = .milliseconds(12)) async throws { try await Task.sleep(for: duration) }
    static func main() async throws {
        #if CONTROLLER_ONLY
        let probe = FeedbackProbe(), feedback = probe.feedback()
        feedback.startOutgoing(id: "A")
        check(probe.players == 1 && probe.plays == 1 && probe.playing, "outgoing audio starts")
        feedback.startOutgoing(id: "A")
        check(probe.players == 1 && probe.plays == 1, "duplicate call start does not stack players")
        feedback.stop(id: "old")
        check(probe.playing, "old call cleanup cannot stop current audio")
        probe.playing = false
        feedback.startOutgoing(id: "A")
        check(probe.players == 1 && probe.plays == 2, "same waiting call can resume paused playback")
        feedback.stop(id: "A")
        check(!probe.playing && probe.stops == 1, "answer/terminal cleanup stops player")
        feedback.stop(id: "A")
        check(probe.stops == 1, "cleanup is idempotent")
        feedback.startIncoming(id: "B")
        check(probe.pulses == 1 && !probe.playing, "incoming emits haptic without second ringtone")
        feedback.startIncoming(id: "B")
        check(probe.pulses == 1, "duplicate incoming has one haptic loop")
        try await settle(.milliseconds(55))
        check(probe.pulses > 1, "foreground waiting repeats haptics")
        feedback.stop(id: "B")
        let stopped = probe.pulses
        try await settle(.milliseconds(45))
        check(probe.pulses == stopped, "no late pulse after answer/stop")
        probe.active = false
        feedback.startIncoming(id: "C")
        try await settle(.milliseconds(30))
        check(probe.pulses == stopped, "background uses system CallKit, no app pulse")
        probe.active = true
        feedback.refreshIncomingActivity()
        check(probe.pulses == stopped + 1, "foreground reentry resumes only pending incoming")
        probe.active = false
        feedback.refreshIncomingActivity()
        let background = probe.pulses
        try await settle(.milliseconds(35))
        check(probe.pulses == background, "resign-active cancels haptic loop")
        feedback.stop(id: "C")
        probe.active = true
        feedback.refreshIncomingActivity()
        check(probe.pulses == background, "answered call cannot restart on foreground")
        feedback.startIncoming(id: "D")
        feedback.startOutgoing(id: "E")
        let switched = probe.pulses
        try await settle(.milliseconds(35))
        check(probe.playing && probe.pulses == switched, "switch to outgoing cancels old pulse")
        feedback.stop(id: "D")
        check(probe.playing, "old incoming end cannot stop new outgoing")
        feedback.stop()
        check(!probe.playing, "provider reset clears feedback")
        let silent = CallWaitingFeedback(makePlayback: { nil }, vibrate: {}, isActive: { true })
        silent.startOutgoing(id: "missing"); silent.stop()
        check(true, "missing audio resource remains safe")
        weak var released: CallWaitingFeedback?
        do { let owned = probe.feedback(); released = owned; owned.startIncoming(id: "release") }
        try await settle(.milliseconds(35))
        check(released == nil, "waiting task does not retain controller")
        print("PASS: \(checks) actual feedback lifecycle checks; Swift 6 complete concurrency; silent counters, not device audio/haptics")
        #else
        func model(_ id: String, probe: FeedbackProbe) -> VideoCallViewModel {
            VideoCallViewModel(session: .init(id: id, roomId: "fixture", peerId: "peer", peerName: "Fixture",
                                            callType: .audio, isIncoming: false, status: .connecting),
                               waitingFeedback: probe.feedback())
        }
        let sdk = TRTCManager.shared
        // Replayed global state from a previous call must not stop this ringback.
        sdk.connectionState = .connected; sdk.remoteParticipants = [.init(id:"peer")]
        let p = FeedbackProbe(), m = model("current", probe: p)
        m.startIfNeeded()
        try await settle()
        check(p.playing && p.plays == 1, "local room entry is not remote answer")
        check(m.session.status == .ringing && m.duration == 0 && m.statusText == "等待对方接听", "local entry remains waiting, without call timer")
        check(!CallHistoryStore.shared.connectedIDs.contains("current"), "own room entry cannot start history duration")
        m.startIfNeeded()
        check(SocketManager.shared.invites == 1 && p.players == 1, "repeat onAppear does not duplicate invite/audio")
        NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo:["from":"peer", "callId":"older"])
        try await settle()
        check(p.playing, "old same-peer call ID cannot silence current ringback")
        NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo:["from":"peer", "callId":"current"])
        try await settle()
        check(!p.playing && p.stops == 1, "remote acceptance stops ringback immediately")
        check(m.session.status == .connected, "answer plus local room ready becomes connected")
        check(CallHistoryStore.shared.connectedIDs.filter { $0 == "current" }.count == 1, "history starts duration on actual connected state")
        m.duration = 12
        sdk.connectionState = .idle
        try await settle()
        NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo:["from":"peer", "callId":"current"])
        try await settle()
        sdk.connectionState = .connected
        try await settle()
        check(m.duration >= 12, "reconnection must not erase the already displayed connected duration")
        sdk.connectionState = .idle; sdk.connectionState = .connected
        try await settle()
        check(!p.playing, "connection/reconnection after answer cannot restart ringtone")
        m.endCall()
        let peerProbe = FeedbackProbe(), peerModel = model("remote-media", probe: peerProbe)
        peerModel.startIfNeeded(); try await settle()
        sdk.remoteParticipants = [.init(id:"someone-else")]
        try await settle()
        check(peerProbe.playing, "unrelated participant does not signal answer")
        sdk.remoteParticipants = [.init(id:"peer")]
        try await settle()
        check(!peerProbe.playing, "peer entry stops ringback if accept signal missing")
        check(peerModel.session.status == .connected, "peer media fallback becomes connected")
        let exitsBeforePeerLeave = sdk.exits
        sdk.remoteParticipants = [.init(id: "someone-else")]
        try await settle()
        check(peerModel.session.status == .ended && sdk.exits == exitsBeforePeerLeave + 1,
              "known peer leaving ends local call even without call_end signal")
        sdk.remoteParticipants = []
        try await settle()
        check(sdk.exits == exitsBeforePeerLeave + 1, "duplicate leave/exit cannot finish call twice")
        let waitingProbe = FeedbackProbe(), waitingModel = model("waiting-peer", probe: waitingProbe)
        waitingModel.startIfNeeded(); try await settle()
        sdk.remoteParticipants = [.init(id: "someone-else")]; try await settle()
        sdk.remoteParticipants = []; try await settle()
        check(waitingModel.session.status == .ringing && waitingProbe.playing,
              "empty room or unrelated peer leaving cannot cancel unanswered call")
        NotificationCenter.default.post(name: .cqimCallEnded, object: nil, userInfo:["from":"peer", "callId":"older"])
        try await settle()
        check(waitingModel.session.status == .ringing, "stale same-peer end ignored")
        check(!waitingModel.session.matchesSignalingEvent(["from":"peer", "callId":"older"]),
              "presentation owner shares strict call ID matching")
        check(waitingModel.session.matchesSignalingEvent(["from":"peer"]), "legacy peer-only end matches")
        check(!waitingModel.session.matchesSignalingEvent(nil), "empty end cannot match empty active session")
        waitingModel.endCall()
        let incomingUUID = UUID()
        var incomingSession = VideoCallSession.incoming(id: incomingUUID.uuidString, callId: "incoming-fixture",
            peerId: "peer", peerName: "Fixture", peerAvatar: nil, roomId: "fixture", callType: .audio)
        incomingSession.status = .connecting
        let incoming = VideoCallViewModel(session: incomingSession, waitingFeedback: FeedbackProbe().feedback())
        incoming.startIfNeeded(); try await settle()
        sdk.remoteParticipants = [.init(id: "peer")]; try await settle()
        let kitEnds = CallManager.shared.endings.count
        sdk.remoteParticipants = []; try await settle()
        check(incoming.session.status == .ended, "incoming peer leave closes presentation state")
        check(CallManager.shared.endings.count == kitEnds + 1, "incoming peer leave releases CallKit call")
        check(CallManager.shared.endings.last?.0 == incomingUUID && CallManager.shared.endings.last?.1 == false,
              "remote hangup cleanup must not echo a hangup signal")
        NotificationCenter.default.post(name: .cqimCallEnded, object: nil, userInfo:["callId":"incoming-fixture"])
        try await settle()
        check(CallManager.shared.endings.count == kitEnds + 1, "late end signal after peer leave is idempotent")
        let rejectedProbe = FeedbackProbe(), rejected = model("reject", probe: rejectedProbe)
        rejected.startIfNeeded(); try await settle()
        NotificationCenter.default.post(name: .cqimCallRejected, object: nil, userInfo:["from":"peer", "callId":"reject"])
        try await settle()
        check(!rejectedProbe.playing && rejected.session.status == .rejected, "rejection stops audio")
        check(CallHistoryStore.shared.endings.contains { $0.0 == "reject" && $0.1 == .declined }, "rejection is recorded")
        let endedProbe = FeedbackProbe(), ended = model("end", probe: endedProbe)
        ended.startIfNeeded(); try await settle()
        ended.endCall()
        check(!endedProbe.playing && ended.session.status == .ended, "local hangup stops audio")
        NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo:["from":"peer", "callId":"end"])
        try await settle()
        check(ended.session.status == .ended && !endedProbe.playing, "late answer cannot revive ended call")
        let remoteEndProbe = FeedbackProbe(), remoteEnd = model("remote-end", probe: remoteEndProbe)
        remoteEnd.startIfNeeded(); try await settle()
        NotificationCenter.default.post(name: .cqimCallEnded, object: nil, userInfo:["from":"peer", "callId":"remote-end"])
        try await settle()
        check(!remoteEndProbe.playing && remoteEnd.session.status == .ended, "remote hangup stops audio")
        let failedProbe = FeedbackProbe()
        APIClient.shared.shouldFail = true
        let failed = model("failed", probe: failedProbe)
        failed.startIfNeeded(); try await settle()
        check(!failedProbe.playing && failed.session.status == .failed, "credential failure stops audio")
        check(CallHistoryStore.shared.endings.contains { $0.0 == "failed" && $0.1 == .failed }, "credential failure is recorded")
        APIClient.shared.shouldFail = false
        let sdkProbe = FeedbackProbe(), sdkModel = model("sdk-fail", probe: sdkProbe)
        sdkModel.startIfNeeded(); try await settle()
        sdk.connectionState = .failed("fixture failure"); try await settle()
        check(!sdkProbe.playing && sdkModel.session.status == .failed, "SDK failure stops audio")
        let legacyProbe = FeedbackProbe(), legacy = model("legacy", probe: legacyProbe)
        legacy.startIfNeeded(); try await settle()
        NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo:["from":"peer"])
        try await settle()
        check(!legacyProbe.playing, "legacy peer-only accept remains supported")
        legacy.endCall()
        APIClient.shared.paused = true
        let earlyProbe = FeedbackProbe(), early = model("early", probe: earlyProbe)
        early.startIfNeeded(); try await settle()
        check(earlyProbe.playing && APIClient.shared.pending != nil, "ringback starts while credentials are pending")
        NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo:["from":"peer", "callId":"early"])
        try await settle()
        check(!earlyProbe.playing && early.session.status == .connecting, "early answer stops audio before local SDK is ready")
        APIClient.shared.resume(); try await settle()
        check(!earlyProbe.playing && early.session.status == .connected, "later local readiness cannot restart audio")
        early.endCall()
        APIClient.shared.paused = true
        let pendingProbe = FeedbackProbe(), pending = model("pending-hangup", probe: pendingProbe)
        pending.startIfNeeded(); try await settle()
        let joinsBeforeHangup = sdk.joins
        pending.endCall()
        APIClient.shared.resume(); try await settle()
        check(!pendingProbe.playing && pending.session.status == .ended && sdk.joins == joinsBeforeHangup,
              "late credentials after hangup cannot join room or restart audio")
        var elapsedClock: TimeInterval = 1000
        let timed = VideoCallViewModel(session: .init(id: "elapsed-clock", roomId: "fixture", peerId: "peer", peerName: "Fixture",
            callType: .audio, isIncoming: false, status: .connecting), waitingFeedback: FeedbackProbe().feedback(), elapsedTime: { elapsedClock })
        timed.startIfNeeded(); try await settle()
        elapsedClock += 30
        timed.refreshDuration()
        check(timed.duration == 0, "ringing time is not connected duration")
        NotificationCenter.default.post(name: .cqimCallAccepted, object: nil, userInfo: ["from": "peer", "callId": "elapsed-clock"])
        try await settle()
        elapsedClock += 65
        timed.refreshDuration()
        check(timed.duration == 65 && timed.formattedDuration == "01:05", "elapsed time catches up without timer ticks")
        elapsedClock -= 10
        timed.refreshDuration()
        check(timed.duration == 65, "duration never moves backwards")
        elapsedClock += 15
        timed.endCall()
        check(timed.duration == 70, "hangup refreshes final elapsed duration")
        elapsedClock += 100
        timed.refreshDuration()
        check(timed.duration == 70, "ended duration stays frozen")
        print("PASS: \(checks) actual ViewModel call-state checks; Swift 5 project mode; fixture network/SDK, not real call proof")
        #endif
    }
}
