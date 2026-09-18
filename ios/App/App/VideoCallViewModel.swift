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
        status: CallStatus
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
    private var didSendInvite = false
    private var didStartRoomJoin = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    init(session: VideoCallSession) {
        self.session = session
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
        if !session.isIncoming, !didSendInvite {
            didSendInvite = true
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
        session.status = .connecting
        SocketManager.shared.sendCallAccept(to: session.peerId)
        Task { await joinRoom() }
    }

    func rejectIncomingCall() {
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
            await manager.enterRoom(roomId: session.roomId, credentials: credentials, callType: session.callType)
            if case .failed(let message) = manager.connectionState {
                errorMessage = message
                session.status = .failed
            }
        } catch {
            errorMessage = error.localizedDescription
            session.status = .failed
        }
    }

    private func bindTRTCState() {
        manager.$connectionState
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor in
                    self?.handleTRTCState(state)
                }
            }
            .store(in: &cancellables)
    }

    private func handleTRTCState(_ state: TRTCConnectionState) {
        guard session.status != .ended, session.status != .rejected else { return }
        switch state {
        case .connected:
            errorMessage = nil
            if session.status != .connected {
                session.status = .connected
                startTimer()
            }
        case .failed(let message):
            errorMessage = message
            session.status = .failed
        default:
            break
        }
    }

    private func startTimer() {
        timer?.invalidate()
        duration = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.duration += 1
            }
        }
    }

    private func bindSignalingObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .cqimCallAccepted, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard self.matchesCurrentCall(notification) else { return }
                self.session.status = .connecting
                await self.joinRoom()
            }
        })

        observers.append(center.addObserver(forName: .cqimCallRejected, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard self.matchesCurrentCall(notification) else { return }
                self.session.status = .rejected
                self.errorMessage = "对方已拒绝"
                self.timer?.invalidate()
                self.manager.exitRoom()
            }
        })

        observers.append(center.addObserver(forName: .cqimCallEnded, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                guard self.matchesCurrentCall(notification) else { return }
                self.session.status = .ended
                self.timer?.invalidate()
                self.manager.exitRoom()
            }
        })
    }

    private func matchesCurrentCall(_ notification: Notification) -> Bool {
        let info = notification.userInfo ?? [:]
        let eventCallId = (info["callId"] as? String) ?? (info["uuid"] as? String)
        if let eventCallId, !eventCallId.isEmpty,
           eventCallId == session.callId || eventCallId == session.id {
            return true
        }

        let eventPeerId = (info["from"] as? String)
            ?? (info["fromUserId"] as? String)
            ?? (info["caller_id"] as? String)
            ?? (info["peerId"] as? String)
        return eventPeerId == session.peerId
    }
}

extension VideoCallSession {
    static func outgoing(peerId: String, peerName: String, peerAvatar: String?, callType: VideoCallType) -> VideoCallSession {
        let currentUserId = UserDefaults.standard.string(forKey: "current_user_id") ?? "ios"
        let roomId = "room-\([currentUserId, peerId].sorted().joined(separator: "-"))-\(Int(Date().timeIntervalSince1970 * 1000))"
        return VideoCallSession(
            roomId: roomId,
            peerId: peerId,
            peerName: peerName,
            peerAvatar: peerAvatar,
            callType: callType,
            isIncoming: false,
            status: .connecting
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
