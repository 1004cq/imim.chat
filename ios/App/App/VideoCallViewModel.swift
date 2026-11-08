import Combine
import Foundation

enum VideoCallType: String, Codable {
    case audio
    case video

    var title: String {
        switch self {
        case .audio: return "语音通话"
        case .video: return "视频通话"
        }
    }
}

struct VideoCallSession: Identifiable, Equatable {
    let id: String
    let callId: String
    let roomId: String
    let peerId: String
    let peerName: String
    let peerAvatar: String?
    let callType: VideoCallType
    let isIncoming: Bool
    let chatID: String?
    var status: CallStatus

    enum CallStatus: String, Equatable {
        case ringing
        case connecting
        case connected
        case ended
        case rejected
        case failed
    }

    init(
        id: String = "call-\(Date().timeIntervalSince1970)",
        callId: String? = nil,
        roomId: String,
        peerId: String,
        peerName: String,
        peerAvatar: String? = nil,
        callType: VideoCallType,
        isIncoming: Bool,
        status: CallStatus,
        chatID: String? = nil
    ) {
        self.id = id
        self.callId = callId ?? id
        self.roomId = roomId
        self.peerId = peerId
        self.peerName = peerName
        self.peerAvatar = peerAvatar
        self.callType = callType
        self.isIncoming = isIncoming
        self.status = status
        self.chatID = chatID
    }
}

@MainActor
final class VideoCallViewModel: ObservableObject {
    @Published var session: VideoCallSession
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var isMinimized = false

    @Published private(set) var manager = TRTCManager.shared

    private var timer: Timer?
    private let elapsedTime: () -> TimeInterval
    private var connectedTime: TimeInterval?
    private var didSendInvite = false
    private var didStartRoomJoin = false
    private var didReceiveRemoteAnswer = false
    private var didSeeRemoteParticipant = false
    private let waitingFeedback: CallWaitingFeedback
    private let history: CallHistoryStore
    private var historyToken: CallHistoryStore.Token?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    init(session: VideoCallSession, waitingFeedback: CallWaitingFeedback? = nil, history: CallHistoryStore? = nil,
         elapsedTime: (() -> TimeInterval)? = nil) {
        self.session = session
        self.waitingFeedback = waitingFeedback ?? CallWaitingFeedback()
        self.history = history ?? CallHistoryStore.shared
        if let elapsedTime {
            self.elapsedTime = elapsedTime
        } else {
            // ContinuousClock includes suspended time and ignores wall-clock changes.
            let origin = ContinuousClock.now
            self.elapsedTime = {
                let elapsed = origin.duration(to: .now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
            }
        }
        bindTRTCState()
        bindSignalingObservers()
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var statusText: String {
        if session.status == .connected {
            return formattedDuration
        }
        if let errorMessage {
            return errorMessage
        }
        if !session.isIncoming, didSendInvite, !didReceiveRemoteAnswer, !isTerminal {
            return "等待对方接听"
        }
        return manager.connectionState.title
    }

    var formattedDuration: String {
        let seconds = Int(duration)
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    func startIfNeeded() {
        guard session.status == .connecting || session.status == .ringing else { return }
        if historyToken == nil {
            historyToken = history.begin(callID: session.callId, peerID: session.peerId,
                mediaKind: session.callType.rawValue, isIncoming: session.isIncoming, chatID: session.chatID)
        }
        if !session.isIncoming, !didSendInvite {
            didSendInvite = true
            waitingFeedback.startOutgoing(id: session.id)
            SocketManager.shared.sendCallInvite(
                to: session.peerId,
                roomId: session.roomId,
                callType: session.callType.rawValue,
                callerName: UserDefaults.standard.string(forKey: "current_user_name") ?? "IMIMChat",
                callerAvatar: UserDefaults.standard.string(forKey: "current_user_avatar"),
                callId: session.id
            )
        }

        if !session.isIncoming || session.status == .connecting {
            Task { await joinRoom() }
        }
    }

    func acceptIncomingCall() {
        waitingFeedback.stop(id: session.id)
        session.status = .connecting
        SocketManager.shared.sendCallAccept(to: session.peerId)
        Task { await joinRoom() }
    }

    func rejectIncomingCall() {
        history.finish(historyToken, reason: .declined)
        waitingFeedback.stop(id: session.id)
        session.status = .rejected
        if session.isIncoming, let uuid = UUID(uuidString: session.id) {
            SocketManager.shared.sendCallReject(to: session.peerId, callId: session.callId)
            CallManager.shared.end(uuid: uuid, reason: .declinedElsewhere, notifyRemote: false)
        } else {
            SocketManager.shared.sendCallReject(to: session.peerId, callId: session.callId)
        }
        manager.exitRoom()
    }

    func endCall() {
        refreshDuration()
        history.finish(historyToken, reason: .endedLocally)
        waitingFeedback.stop(id: session.id)
        if session.isIncoming, let uuid = UUID(uuidString: session.id) {
            CallManager.shared.end(uuid: uuid, reason: .remoteEnded)
        } else {
            SocketManager.shared.sendCallEnd(to: session.peerId, callId: session.callId)
        }
        session.status = .ended
        timer?.invalidate()
        manager.exitRoom()
    }

    func toggleMute() { manager.toggleMute() }
    func toggleCamera() { manager.toggleCamera() }
    func toggleSpeaker() { manager.toggleSpeaker() }
    func switchCamera() { manager.switchCamera() }
    func toggleScreenSharing() { manager.toggleScreenSharing() }

    private func joinRoom() async {
        guard !didStartRoomJoin else { return }
        didStartRoomJoin = true
        do {
            errorMessage = nil
            let credentials = try await APIClient.shared.fetchTRTCUserSig()
            guard !Task.isCancelled, !isTerminal else { return }
            await manager.enterRoom(roomId: session.roomId, credentials: credentials, callType: session.callType)
            guard !Task.isCancelled, !isTerminal else { return }
            if case .failed(let message) = manager.connectionState {
                history.finish(historyToken, reason: .failed)
                waitingFeedback.stop(id: session.id)
                errorMessage = message
                session.status = .failed
            }
        } catch {
            guard !isTerminal else { return }
            history.finish(historyToken, reason: .failed)
            waitingFeedback.stop(id: session.id)
            errorMessage = error.localizedDescription
            session.status = .failed
        }
    }

    private func bindTRTCState() {
        manager.$connectionState
            .dropFirst() // Do not replay the previous call's shared SDK state.
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor in
                    self?.handleTRTCState(state)
                }
            }
            .store(in: &cancellables)

        manager.$remoteParticipants
            .dropFirst()
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] ids in
                Task { @MainActor [weak self] in
                    guard let self, self.didStartRoomJoin, !self.isTerminal else { return }
                    if ids.contains(self.session.peerId) {
                        self.didSeeRemoteParticipant = true
                        self.markRemoteAnswered()
                    } else if self.didSeeRemoteParticipant {
                        // TRTC confirms a previously joined peer left. End even
                        // if their WebSocket call_end was lost; an initially
                        // empty room must never cancel an unanswered call.
                        self.finishRemoteCall()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func handleTRTCState(_ state: TRTCConnectionState) {
        guard didStartRoomJoin, !isTerminal else { return }
        switch state {
        case .connected:
            // Our own TRTC room entry is not the other person's answer.
            if !session.isIncoming, !didReceiveRemoteAnswer {
                waitingFeedback.startOutgoing(id: session.id)
                session.status = .ringing
                return
            }
            errorMessage = nil
            if session.status != .connected {
                history.connected(historyToken)
                session.status = .connected
                startTimer()
            }
        case .failed(let message):
            refreshDuration()
            history.finish(historyToken, reason: .failed)
            waitingFeedback.stop(id: session.id)
            timer?.invalidate()
            errorMessage = message
            session.status = .failed
        default:
            break
        }
    }

    private var isTerminal: Bool {
        session.status == .ended || session.status == .rejected || session.status == .failed
    }

    private func markRemoteAnswered() {
        didReceiveRemoteAnswer = true
        waitingFeedback.stop(id: session.id)
        if didStartRoomJoin, manager.connectionState == .connected {
            handleTRTCState(.connected)
        } else {
            session.status = .connecting
        }
    }

    private func finishRemoteCall() {
        guard !isTerminal else { return }
        refreshDuration()
        history.finish(historyToken, reason: .endedRemotely)
        waitingFeedback.stop(id: session.id)
        session.status = .ended
        timer?.invalidate()
        if session.isIncoming, let uuid = UUID(uuidString: session.id) {
            CallManager.shared.end(uuid: uuid, reason: .remoteEnded, notifyRemote: false)
        }
        manager.exitRoom()
        #if DEBUG
        print("[CallAudio] event=remote_call_finished")
        #endif
    }

    private func startTimer() {
        timer?.invalidate()
        if connectedTime == nil { connectedTime = elapsedTime() }
        refreshDuration()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDuration()
            }
        }
        timer?.tolerance = 0.1
    }

    func refreshDuration() {
        guard !isTerminal, let connectedTime else { return }
        let elapsed = elapsedTime() - connectedTime
        guard elapsed.isFinite else { return }
        duration = max(duration, max(0, elapsed))
    }

    private func bindSignalingObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .cqimCallAccepted, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isTerminal, self.matchesCurrentCall(notification) else { return }
                self.markRemoteAnswered()
                await self.joinRoom()
            }
        })

        observers.append(center.addObserver(forName: .cqimCallRejected, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isTerminal, self.matchesCurrentCall(notification) else { return }
                self.history.finish(self.historyToken, reason: .declined)
                self.waitingFeedback.stop(id: self.session.id)
                self.session.status = .rejected
                self.errorMessage = "对方已拒绝"
                self.timer?.invalidate()
                self.manager.exitRoom()
            }
        })

        observers.append(center.addObserver(forName: .cqimCallEnded, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isTerminal, self.matchesCurrentCall(notification) else { return }
                self.finishRemoteCall()
            }
        })
    }

    private func matchesCurrentCall(_ notification: Notification) -> Bool {
        session.matchesSignalingEvent(notification.userInfo)
    }
}

extension VideoCallSession {
    func matchesSignalingEvent(_ userInfo: [AnyHashable: Any]?) -> Bool {
        let info = userInfo ?? [:]
        let eventCallId = (info["callId"] as? String) ?? (info["uuid"] as? String)
        if let eventCallId, !eventCallId.isEmpty {
            return eventCallId == callId || eventCallId == id
        }

        let eventPeerId = (info["from"] as? String)
            ?? (info["fromUserId"] as? String)
            ?? (info["caller_id"] as? String)
            ?? (info["peerId"] as? String)
        return eventPeerId == peerId
    }
}

extension VideoCallSession {
    static func outgoing(peerId: String, peerName: String, peerAvatar: String?, callType: VideoCallType, chatID: String? = nil) -> VideoCallSession {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id") ?? "ios"
        let roomId = "room-\([currentUserId, peerId].sorted().joined(separator: "-"))-\(Int(Date().timeIntervalSince1970 * 1000))"
        return VideoCallSession(
            roomId: roomId,
            peerId: peerId,
            peerName: peerName,
            peerAvatar: peerAvatar,
            callType: callType,
            isIncoming: false,
            status: .connecting,
            chatID: chatID
        )
    }

    static func incoming(id: String = "call-\(Date().timeIntervalSince1970)", callId: String? = nil, peerId: String, peerName: String, peerAvatar: String?, roomId: String, callType: VideoCallType) -> VideoCallSession {
        VideoCallSession(
            id: id,
            callId: callId,
            roomId: roomId,
            peerId: peerId,
            peerName: peerName,
            peerAvatar: peerAvatar,
            callType: callType,
            isIncoming: true,
            status: .ringing
        )
    }
}
