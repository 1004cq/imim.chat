import AVFoundation
import Combine
import SwiftUI
import UIKit

#if canImport(TXLiteAVSDK_Professional)
import TXLiteAVSDK_Professional
#elseif canImport(TXLiteAVSDK_TRTC)
import TXLiteAVSDK_TRTC
#endif

enum TRTCConnectionState: Equatable {
    case idle
    case requestingPermission
    case joining
    case connected
    case reconnecting
    case disconnected
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "准备通话"
        case .requestingPermission: return "正在检查权限"
        case .joining: return "正在连接..."
        case .connected: return "通话中"
        case .reconnecting: return "正在重连..."
        case .disconnected: return "已断开"
        case .failed(let message): return message
        }
    }
}

struct TRTCCredentials: Codable {
    let sdkAppId: Int
    let userId: String
    let userSig: String
    let expireTime: Int?

    enum CodingKeys: String, CodingKey {
        case sdkAppId, sdkAppID, SDKAppID
        case userId, userID
        case userSig, UserSig
        case expireTime
    }

    init(sdkAppId: Int, userId: String, userSig: String, expireTime: Int? = nil) {
        self.sdkAppId = sdkAppId
        self.userId = userId
        self.userSig = userSig
        self.expireTime = expireTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sdkAppId = try container.decodeIfPresent(Int.self, forKey: .sdkAppId)
            ?? container.decodeIfPresent(Int.self, forKey: .sdkAppID)
            ?? container.decodeIfPresent(Int.self, forKey: .SDKAppID)
            ?? 0
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
            ?? container.decodeIfPresent(String.self, forKey: .userID)
            ?? ""
        userSig = try container.decodeIfPresent(String.self, forKey: .userSig)
            ?? container.decodeIfPresent(String.self, forKey: .UserSig)
            ?? ""
        expireTime = try container.decodeIfPresent(Int.self, forKey: .expireTime)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sdkAppId, forKey: .sdkAppId)
        try container.encode(userId, forKey: .userId)
        try container.encode(userSig, forKey: .userSig)
        try container.encodeIfPresent(expireTime, forKey: .expireTime)
    }
}

struct TRTCRemoteParticipant: Identifiable, Equatable {
    let id: String
    var hasVideo: Bool
    var hasAudio: Bool
    var volume: Int

    init(id: String, hasVideo: Bool = false, hasAudio: Bool = true, volume: Int = 0) {
        self.id = id
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.volume = volume
    }
}

@MainActor
final class TRTCManager: NSObject, ObservableObject {
    static let shared = TRTCManager()

    @Published private(set) var connectionState: TRTCConnectionState = .idle
    @Published private(set) var remoteParticipants: [TRTCRemoteParticipant] = []
    @Published private(set) var localVolume: Int = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraOff = false
    @Published private(set) var isSpeakerOn = true
    @Published private(set) var isFrontCamera = true
    @Published private(set) var isScreenSharing = false
    @Published private(set) var mediaWarning: String?
    @Published private(set) var isDualCameraEnabled = false
    @Published private(set) var isChangingCamera = false

    var canStartCameraCapture: Bool { activeRoomId == nil }
    var canUseDualCamera: Bool { AVCaptureMultiCamSession.isMultiCamSupported && activeCallType == .video }
    private var dualCamera: DualCameraCaptureEngine?
    private var dualPreview: DualCameraPreviewSurface?
    private var dualSink: TRTCCompositeVideoSink?
    private var cameraTransition = UUID()

    private var localView: UIView?
    private var remoteViews: [String: UIView] = [:]
    private var activeRoomId: String?
    private var activeCallType: VideoCallType = .video
    private var isSDKConfigured = false
    private var callKitAudioActivationRequired = false
    private var callKitAudioSessionActive = false
    private var localMediaStarted = false
    private var didRetryAudioStart = false
    private var audioStartRetryTask: Task<Void, Never>?
    #if DEBUG
    private var lastAudioDiagnosticTime: TimeInterval = 0
    #endif

    private override init() {
        super.init()
    }

    @discardableResult
    private func configureSDKIfNeeded() -> Bool {
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        guard !isSDKConfigured else { return true }
        let cloud = TRTCCloud.sharedInstance()
        cloud.addDelegate(self)
        isSDKConfigured = true
        return true
        #else
        return false
        #endif
    }

    func bindLocalPreview(_ view: UIView) {
        localView = view
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if let dualCamera {
            attachDualPreview(to: view, engine: dualCamera)
        } else if !isChangingCamera, isSDKConfigured, activeRoomId != nil, activeCallType == .video, !isCameraOff {
            TRTCCloud.sharedInstance().startLocalPreview(isFrontCamera, view: view)
        }
        #endif
    }

    func bindRemoteView(_ view: UIView, userId: String) {
        remoteViews[userId] = view
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured, remoteParticipants.contains(where: { $0.id == userId && $0.hasVideo }) {
            TRTCCloud.sharedInstance().startRemoteView(userId, streamType: .big, view: view)
        }
        #endif
    }

    func enterRoom(roomId: String, credentials: TRTCCredentials, callType: VideoCallType) async {
        guard !roomId.isEmpty else {
            connectionState = .failed("房间号为空")
            return
        }

        activeRoomId = roomId
        activeCallType = callType
        mediaWarning = nil
        isMuted = false
        isCameraOff = callType == .audio
        isSpeakerOn = true
        localVolume = 0
        remoteParticipants.removeAll()
        didRetryAudioStart = false
        audioStartRetryTask?.cancel()
        audioStartRetryTask = nil
        guard credentials.sdkAppId > 0 else {
            connectionState = .failed("TRTC SDKAppID 无效")
            return
        }

        guard !credentials.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionState = .failed("TRTC 用户 ID 为空")
            return
        }

        guard !credentials.userSig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionState = .failed("TRTC UserSig 为空")
            return
        }

        connectionState = .requestingPermission

        // A composing camera/recorder yields its lease before TRTC acquires video or audio.
        await DualCameraCaptureEngine.yieldToCall()
        guard activeRoomId == roomId, !Task.isCancelled else { return }

        let permission = await requestMediaPermission(callType: callType)
        guard activeRoomId == roomId, !Task.isCancelled else { return }
        guard permission else {
            connectionState = .failed("请在系统设置中允许相机/麦克风权限")
            return
        }

        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        guard configureSDKIfNeeded() else {
            connectionState = .failed("未集成 TRTC iOS SDK，请先安装 TXLiteAVSDK_Professional")
            return
        }

        // Video preview is safe before room entry. Audio must wait for onEnterRoom.
        startLocalPreviewBeforeRoomEntry()
        connectionState = .joining

        let params = TRTCParams()
        params.sdkAppId = UInt32(credentials.sdkAppId)
        params.userId = credentials.userId
        params.userSig = credentials.userSig
        params.roomId = numericRoomId(from: roomId)
        params.strRoomId = ""
        params.role = .anchor

        print("[TRTC] entering room id=\(params.roomId) sdkAppId=\(credentials.sdkAppId) userId=\(credentials.userId) type=\(callType.rawValue)")
        TRTCCloud.sharedInstance().enterRoom(params, appScene: .videoCall)
        #else
        connectionState = .failed("未集成 TRTC iOS SDK，请先安装 TXLiteAVSDK_Professional")
        #endif
    }

    func exitRoom() {
        cameraTransition = UUID()
        dualSink?.invalidate(); dualSink = nil
        dualCamera?.stop(); dualCamera = nil
        dualPreview?.removeFromSuperview(); dualPreview = nil
        isDualCameraEnabled = false; isChangingCamera = false
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured {
            TRTCCloud.sharedInstance().stopLocalPreview()
            TRTCCloud.sharedInstance().enableCustomVideoCapture(.big, enable: false)
            TRTCCloud.sharedInstance().stopLocalAudio()
            for participant in remoteParticipants {
                TRTCCloud.sharedInstance().stopRemoteView(participant.id, streamType: .big)
            }
            TRTCCloud.sharedInstance().exitRoom()
        }
        #endif

        audioStartRetryTask?.cancel()
        audioStartRetryTask = nil
        if !callKitAudioActivationRequired {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        activeRoomId = nil
        localMediaStarted = false
        callKitAudioActivationRequired = false
        callKitAudioSessionActive = false
        remoteViews.removeAll()
        remoteParticipants.removeAll()
        localVolume = 0
        connectionState = .disconnected
    }

    func toggleMute() {
        isMuted.toggle()
        applyMutedState()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyMutedState()
    }

    @discardableResult
    func prepareForCallKitAudioActivation(callType: VideoCallType) -> Bool {
        activeCallType = callType
        // Configure without taking activation away from CallKit. This must run
        // before CXAnswerCallAction/CXStartCallAction is fulfilled.
        guard configureAudioSession(AVAudioSession.sharedInstance(), activate: false) else { return false }
        callKitAudioActivationRequired = true
        callKitAudioSessionActive = false
        logAudioState("callkit_prepared")
        return true
    }

    func handleCallKitAudioSessionActivated(_ session: AVAudioSession) {
        guard callKitAudioActivationRequired else { return }
        // CallKit has already activated the preconfigured session. Do not change
        // category/mode here or enqueue work that can reorder this signal.
        callKitAudioSessionActive = true
        logAudioState("callkit_activated", session: session)
        if connectionState == .connected {
            startLocalMediaAfterRoomEntered()
        }
    }

    func handleCallKitAudioSessionDeactivated() {
        // A late callback from a finished system call must not stop a new call
        // whose audio session is owned directly by the App.
        guard callKitAudioActivationRequired else { return }
        callKitAudioSessionActive = false
        audioStartRetryTask?.cancel()
        audioStartRetryTask = nil
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured, localMediaStarted {
            TRTCCloud.sharedInstance().stopLocalAudio()
        }
        #endif
        localMediaStarted = false
        logAudioState("callkit_deactivated")
    }

    private func applyMutedState() {
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured, localMediaStarted {
            TRTCCloud.sharedInstance().muteLocalAudio(isMuted)
        }
        #endif
    }

    func toggleCamera() {
        guard !isChangingCamera else { return }
        if dualCamera != nil {
            // Release custom capture fully before restoring the SDK's own camera.
            disableDualCamera(turnCameraOff: true)
            return
        }
        guard !shouldDisableLocalVideoForCurrentRuntime else {
            isCameraOff = true
            mediaWarning = videoCompatibilityWarning
            return
        }

        isCameraOff.toggle()
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured {
            if localMediaStarted {
                TRTCCloud.sharedInstance().muteLocalVideo(.big, mute: isCameraOff)
            }
            if !isCameraOff, let localView {
                TRTCCloud.sharedInstance().startLocalPreview(isFrontCamera, view: localView)
            } else if isCameraOff {
                TRTCCloud.sharedInstance().stopLocalPreview()
            }
        }
        #endif
    }

    func switchCamera() {
        guard !isChangingCamera else { return }
        if let dualCamera {
            isFrontCamera.toggle()
            dualCamera.setFrontMain(isFrontCamera)
            return
        }
        guard !shouldDisableLocalVideoForCurrentRuntime else {
            isCameraOff = true
            mediaWarning = videoCompatibilityWarning
            return
        }

        isFrontCamera.toggle()
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured {
            TRTCCloud.sharedInstance().getDeviceManager().switchCamera(isFrontCamera)
        }
        #endif
    }

    func toggleDualCamera() {
        guard !isChangingCamera, activeRoomId != nil, activeCallType == .video, !isCameraOff else { return }
        if dualCamera != nil { disableDualCamera(turnCameraOff: false); return }
        guard canUseDualCamera else {
            mediaWarning = AppLocalization.string("此设备使用单摄拍摄"); return
        }
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        guard isSDKConfigured else { return }
        let transition = UUID(); cameraTransition = transition
        isChangingCamera = true
        let cloud = TRTCCloud.sharedInstance()
        cloud.stopLocalPreview()
        cloud.enableCustomVideoCapture(.big, enable: true)
        let engine = DualCameraCaptureEngine()
        let sink = TRTCCompositeVideoSink()
        dualCamera = engine; dualSink = sink
        // Rear main + front inset on entry; the existing flip control swaps them.
        isFrontCamera = false
        if let localView { attachDualPreview(to: localView, engine: engine) }
        engine.start(onState: { [weak self] running, dual, failure in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cameraTransition == transition, self.dualCamera === engine else { return }
                self.isChangingCamera = false
                self.isDualCameraEnabled = running && dual
                if let failure { self.mediaWarning = failure.localizedDescription }
                if !running, failure != .interrupted { self.disableDualCamera(turnCameraOff: false) }
            }
        }, onFrame: { buffer, pts in sink.send(buffer, pts: pts) })
        cloud.muteLocalVideo(.big, mute: false)
        #endif
    }

    private func attachDualPreview(to view: UIView, engine: DualCameraCaptureEngine) {
        dualPreview?.removeFromSuperview()
        let surface = DualCameraPreviewSurface(frame: view.bounds)
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(surface); dualPreview = surface
        engine.bindPreview(surface.displayLayer.sampleBufferRenderer)
    }

    private func disableDualCamera(turnCameraOff: Bool) {
        guard let engine = dualCamera else { return }
        let transition = UUID(); cameraTransition = transition
        isChangingCamera = true; isDualCameraEnabled = false
        dualSink?.invalidate(); dualSink = nil
        // Keep the engine identity until the session actually releases the devices.
        engine.stop { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cameraTransition == transition else { return }
                self.dualCamera = nil
                self.dualPreview?.removeFromSuperview(); self.dualPreview = nil
                self.isChangingCamera = false; self.isCameraOff = turnCameraOff
                #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
                let cloud = TRTCCloud.sharedInstance()
                cloud.enableCustomVideoCapture(.big, enable: false)
                if self.activeRoomId != nil {
                    cloud.muteLocalVideo(.big, mute: turnCameraOff)
                    if !turnCameraOff, let view = self.localView {
                        cloud.startLocalPreview(self.isFrontCamera, view: view)
                    }
                }
                #endif
            }
        }
    }

    func toggleSpeaker() {
        guard connectionState == .connected, localMediaStarted else { return }
        setSpeakerEnabled(!isSpeakerOn)
    }

    func toggleScreenSharing() {
        guard connectionState == .connected, !remoteParticipants.isEmpty else { return }
        isScreenSharing.toggle()
        // iOS 屏幕共享需要 Broadcast Upload Extension，当前先保留 UI 状态入口。
    }

    private func setSpeakerEnabled(_ enabled: Bool) {
        isSpeakerOn = enabled
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured {
            TRTCCloud.sharedInstance().setAudioRoute(enabled ? .modeSpeakerphone : .modeEarpiece)
        } else {
            try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        }
        #else
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
        #endif
    }

    private func requestMediaPermission(callType: VideoCallType) async -> Bool {
        let audioAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard audioAllowed else { return false }
        if callType == .video {
            return await AVCaptureDevice.requestAccess(for: .video)
        }
        return true
    }

    private func upsertRemoteUser(_ userId: String, hasVideo: Bool? = nil, hasAudio: Bool? = nil, volume: Int? = nil) {
        if let index = remoteParticipants.firstIndex(where: { $0.id == userId }) {
            if let hasVideo { remoteParticipants[index].hasVideo = hasVideo }
            if let hasAudio { remoteParticipants[index].hasAudio = hasAudio }
            if let volume { remoteParticipants[index].volume = volume }
        } else {
            remoteParticipants.append(
                TRTCRemoteParticipant(
                    id: userId,
                    hasVideo: hasVideo ?? false,
                    hasAudio: hasAudio ?? true,
                    volume: volume ?? 0
                )
            )
        }
    }

    private func numericRoomId(from roomId: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in roomId.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return max(1, min(hash, 4_294_967_294))
    }

    private func startLocalMediaAfterRoomEntered() {
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        guard isSDKConfigured else { return }
        guard !callKitAudioActivationRequired || callKitAudioSessionActive else {
            logAudioState("waiting_for_callkit")
            return
        }
        guard !localMediaStarted else { return }

        if !callKitAudioActivationRequired {
            guard configureAudioSession(AVAudioSession.sharedInstance(), activate: true) else { return }
        }

        localMediaStarted = true
        let cloud = TRTCCloud.sharedInstance()
        let volumeParams = TRTCAudioVolumeEvaluateParams()
        volumeParams.interval = 300
        volumeParams.enableVadDetection = true
        cloud.enableAudioVolumeEvaluation(true, with: volumeParams)
        cloud.startLocalAudio(.speech)
        cloud.muteLocalAudio(isMuted)
        cloud.muteAllRemoteAudio(false)

        if activeCallType == .video, shouldDisableLocalVideoForCurrentRuntime {
            isCameraOff = true
            mediaWarning = videoCompatibilityWarning
        } else if activeCallType == .video, let localView {
            isCameraOff = false
            if dualCamera == nil, !isChangingCamera { cloud.startLocalPreview(isFrontCamera, view: localView) }
            cloud.muteLocalVideo(.big, mute: false)
        } else {
            isCameraOff = true
        }

        setSpeakerEnabled(true)
        logAudioState("local_audio_started")
        #endif
    }

    private func configureAudioSession(_ session: AVAudioSession, activate: Bool) -> Bool {
        do {
            let mode: AVAudioSession.Mode = activeCallType == .video ? .videoChat : .voiceChat
            try session.setCategory(
                .playAndRecord,
                mode: mode,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            if activate {
                try session.setActive(true)
            }
            return true
        } catch {
            #if DEBUG
            print("[CallAudio] session_error code=\((error as NSError).code)")
            #endif
            mediaWarning = "无法激活通话音频：\(error.localizedDescription)"
            return false
        }
    }

    /// Debug-only diagnostics: no user/room IDs, names, tokens or device names.
    private func logAudioState(_ event: String, session: AVAudioSession = .sharedInstance()) {
        #if DEBUG
        let inputs = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("[CallAudio] event=\(event) kitRequired=\(callKitAudioActivationRequired) kitActive=\(callKitAudioSessionActive) localStarted=\(localMediaStarted) muted=\(isMuted) category=\(session.category.rawValue) mode=\(session.mode.rawValue) input=\(inputs) output=\(outputs) inputAvailable=\(session.isInputAvailable) systemVolume=\(session.outputVolume) micPermission=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        if isSDKConfigured {
            let cloud = TRTCCloud.sharedInstance()
            print("[CallAudio] captureVolume=\(cloud.getAudioCaptureVolume()) playoutVolume=\(cloud.getAudioPlayoutVolume()) peers=\(remoteParticipants.count) audioPeers=\(remoteParticipants.filter { $0.hasAudio }.count)")
        }
        #endif
        #endif
    }

    private func retryLocalAudioAfterFailure() {
        guard connectionState == .connected, localMediaStarted else { return }
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        TRTCCloud.sharedInstance().stopLocalAudio()
        localMediaStarted = false
        startLocalMediaAfterRoomEntered()
        #endif
    }

    private func startLocalPreviewBeforeRoomEntry() {
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        guard isSDKConfigured,
              dualCamera == nil, !isChangingCamera,
              activeCallType == .video,
              !isCameraOff,
              let localView else { return }
        TRTCCloud.sharedInstance().startLocalPreview(isFrontCamera, view: localView)
        #endif
    }

    private func showTemporaryMediaWarning(_ message: String) {
        mediaWarning = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard self?.mediaWarning == message else { return }
            self?.mediaWarning = nil
        }
    }

    private var shouldDisableLocalVideoForCurrentRuntime: Bool {
        #if targetEnvironment(simulator)
        return activeCallType == .video && ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #else
        return false
        #endif
    }

    private var videoCompatibilityWarning: String {
        "当前 iOS 27 beta 与 TRTC 13.4 视频采集可能不兼容，已临时关闭摄像头避免闪退"
    }
}

#if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
extension TRTCManager: TRTCCloudDelegate {
    nonisolated func onError(_ errCode: TXLiteAVError, errMsg: String?, extInfo: [AnyHashable: Any]?) {
        Task { @MainActor [self] in
            print("[TRTC] error code=\(errCode.rawValue)")
            logAudioState("sdk_error")

            // -1321 is an audio-device startup warning, not a room-entry failure.
            // Retry once after the audio session has settled, then keep the call UI usable.
            if errCode.rawValue == -1321 {
                guard !didRetryAudioStart else {
                    showTemporaryMediaWarning("音频暂时不可用，请检查麦克风或蓝牙设备")
                    return
                }
                didRetryAudioStart = true
                audioStartRetryTask?.cancel()
                audioStartRetryTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self?.retryLocalAudioAfterFailure()
                }
                return
            }

            switch connectionState {
            case .requestingPermission, .joining:
                connectionState = .failed("通话连接失败，请稍后重试")
            default:
                showTemporaryMediaWarning("通话媒体出现异常，请稍后重试")
            }
        }
    }

    nonisolated func onEnterRoom(_ result: Int) {
        Task { @MainActor in
            if result >= 0 {
                print("[TRTC] entered room in \(result) ms")
                connectionState = .connected
                startLocalMediaAfterRoomEntered()
            } else {
                print("[TRTC] enter room failed: \(result)")
                connectionState = .failed("进房失败 \(result)")
            }
        }
    }

    nonisolated func onExitRoom(_ reason: Int) {
        Task { @MainActor in
            connectionState = .disconnected
            remoteParticipants.removeAll()
        }
    }

    nonisolated func onRemoteUserEnterRoom(_ userId: String) {
        Task { @MainActor in
            upsertRemoteUser(userId)
        }
    }

    nonisolated func onRemoteUserLeaveRoom(_ userId: String, reason: Int) {
        Task { @MainActor in
            remoteParticipants.removeAll { $0.id == userId }
            remoteViews.removeValue(forKey: userId)
        }
    }

    nonisolated func onUserVideoAvailable(_ userId: String, available: Bool) {
        Task { @MainActor in
            upsertRemoteUser(userId, hasVideo: available)
            guard available, let view = remoteViews[userId] else { return }
            TRTCCloud.sharedInstance().startRemoteView(userId, streamType: .big, view: view)
        }
    }

    nonisolated func onUserAudioAvailable(_ userId: String, available: Bool) {
        Task { @MainActor in
            upsertRemoteUser(userId, hasAudio: available)
            logAudioState("remote_audio_availability")
        }
    }

    nonisolated func onConnectionLost() {
        Task { @MainActor in
            connectionState = .reconnecting
        }
    }

    nonisolated func onConnectionRecovery() {
        Task { @MainActor in
            connectionState = .connected
        }
    }

    nonisolated func onUserVoiceVolume(_ userVolumes: [TRTCVolumeInfo], totalVolume: Int) {
        Task { @MainActor in
            for item in userVolumes {
                let userId = item.userId ?? ""
                if userId.isEmpty {
                    localVolume = Int(item.volume)
                } else {
                    upsertRemoteUser(userId, volume: Int(item.volume))
                }
            }
            #if DEBUG
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAudioDiagnosticTime >= 5 {
                lastAudioDiagnosticTime = now
                print("[CallAudio] localLevel=\(localVolume) remoteMaxLevel=\(remoteParticipants.map(\.volume).max() ?? 0) totalLevel=\(totalVolume)")
                logAudioState("volume_sample")
            }
            #endif
        }
    }
}
#endif

/// The small lock is an SDK send/teardown gate, not a media queue or async wait.
/// Invalidation waits for a current send to finish before exitRoom switches SDK modes.
private final class TRTCCompositeVideoSink: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func invalidate() { lock.lock(); enabled = false; lock.unlock() }
    func send(_ buffer: CVPixelBuffer, pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        #if canImport(TXLiteAVSDK_Professional) || canImport(TXLiteAVSDK_TRTC)
        let frame = TRTCVideoFrame()
        frame.pixelFormat = ._32BGRA
        frame.bufferType = .pixelBuffer
        frame.pixelBuffer = buffer
        frame.width = UInt32(CVPixelBufferGetWidth(buffer))
        frame.height = UInt32(CVPixelBufferGetHeight(buffer))
        frame.timestamp = TRTCCloud.generateCustomPTS()
        TRTCCloud.sharedInstance().sendCustomVideoData(.big, frame: frame)
        #endif
    }
}

struct TRTCVideoCanvas: UIViewRepresentable {
    enum Role {
        case local
        case remote(String)
    }

    let role: Role

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor.black
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous

        Task { @MainActor in
            switch role {
            case .local:
                TRTCManager.shared.bindLocalPreview(view)
            case .remote(let userId):
                TRTCManager.shared.bindRemoteView(view, userId: userId)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
