import AVFoundation
import Combine
import Foundation
import Speech
import CallKit
import NaturalLanguage
import UIKit

struct VoiceRecordingResult {
    let fileURL: URL
    let duration: Double
    let waveform: [Double]
    let mimeType: String
}

enum VoiceRecorderError: LocalizedError {
    case permissionDenied
    case recordingTooShort
    case missingRecording
    case playbackUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "请在系统设置中允许麦克风权限"
        case .recordingTooShort: return "录音时间太短"
        case .missingRecording: return "录音文件不存在"
        case .playbackUnavailable: return "语音暂时无法播放"
        }
    }
}

@MainActor
final class VoiceRecorderManager: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isCancelling = false
    @Published var isPlaying = false
    @Published var playingMessageId: String?
    @Published var playbackProgress: Double = 0
    @Published var recordingDuration: Double = 0
    @Published var livePower: Double = 0
    @Published var liveWaveform: [Double] = Array(repeating: 0.18, count: 28)
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private var playbackTimer: Timer?
    private var recordingStartedAt: Date?
    private var currentRecordingURL: URL?

    private let minDuration: Double = 0.7
    private let maxDuration: Double = 60

    func beginRecording() async {
        guard !isRecording else { return }
        errorMessage = nil

        let hasPermission = await requestMicrophonePermission()
        guard hasPermission else {
            errorMessage = VoiceRecorderError.permissionDenied.localizedDescription
            return
        }

        do {
            try configureSessionForRecording()
            let url = makeRecordingURL()
            currentRecordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.record(forDuration: maxDuration)
            self.recorder = recorder
            recordingStartedAt = Date()
            recordingDuration = 0
            liveWaveform = Array(repeating: 0.18, count: 28)
            isCancelling = false
            isRecording = true
            startMetering()
        } catch {
            errorMessage = error.localizedDescription
            cleanupRecording()
        }
    }

    func updateCancelState(translation: CGSize) {
        isCancelling = translation.height < -54
    }

    func finishRecording(cancelled: Bool = false) throws -> VoiceRecordingResult {
        guard let recorder, let startedAt = recordingStartedAt else {
            throw VoiceRecorderError.missingRecording
        }

        let url = recorder.url
        let duration = max(Date().timeIntervalSince(startedAt), recorder.currentTime)
        recorder.stop()
        stopMetering()

        defer {
            cleanupRecording(keepFile: !cancelled)
        }

        if cancelled {
            try? FileManager.default.removeItem(at: url)
            throw VoiceRecorderError.missingRecording
        }

        guard duration >= minDuration else {
            try? FileManager.default.removeItem(at: url)
            throw VoiceRecorderError.recordingTooShort
        }

        return VoiceRecordingResult(
            fileURL: url,
            duration: duration,
            waveform: normalizedWaveform(liveWaveform),
            mimeType: "audio/mp4"
        )
    }

    func cancelRecording() {
        recorder?.stop()
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        cleanupRecording()
    }

    func togglePlayback(messageId: String, urlString: String?) {
        if playingMessageId == messageId, isPlaying {
            stopPlayback()
            return
        }

        stopPlayback()
        guard let audioURL = resolvedURL(from: urlString) else {
            errorMessage = VoiceRecorderError.playbackUnavailable.localizedDescription
            return
        }

        Task {
            do {
                try await play(messageId: messageId, url: audioURL)
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.stopPlayback()
                }
            }
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        isPlaying = false
        playingMessageId = nil
        playbackProgress = 0
    }

    private func play(messageId: String, url: URL) async throws {
        try configureSessionForPlayback()
        let localURL: URL
        if url.isFileURL {
            localURL = url
        } else {
            let (downloadedURL, _) = try await URLSession.shared.download(from: url)
            localURL = downloadedURL
        }

        let player = try AVAudioPlayer(contentsOf: localURL)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        self.playingMessageId = messageId
        self.isPlaying = true
        self.playbackProgress = 0
        player.play()
        startPlaybackTimer()
    }

    private func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func configureSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    private func configureSessionForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let level = self.normalizedPower(recorder.averagePower(forChannel: 0))
                self.livePower = level
                self.recordingDuration = recorder.currentTime
                self.liveWaveform.append(level)
                if self.liveWaveform.count > 36 {
                    self.liveWaveform.removeFirst()
                }

                if recorder.currentTime >= self.maxDuration {
                    _ = try? self.finishRecording()
                }
            }
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.playbackProgress = player.duration > 0 ? min(1, player.currentTime / player.duration) : 0
                if !player.isPlaying {
                    self.stopPlayback()
                }
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func cleanupRecording(keepFile: Bool = false) {
        if !keepFile, let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        recorder = nil
        currentRecordingURL = nil
        recordingStartedAt = nil
        isRecording = false
        isCancelling = false
        livePower = 0
        recordingDuration = 0
        stopMetering()
    }

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
    }

    private func normalizedPower(_ db: Float) -> Double {
        if db < -55 { return 0.08 }
        let level = pow(10, Double(db) / 35)
        return min(1, max(0.08, level))
    }

    private func normalizedWaveform(_ samples: [Double], targetCount: Int = 32) -> [Double] {
        guard !samples.isEmpty else { return Array(repeating: 0.2, count: targetCount) }
        if samples.count <= targetCount {
            return samples + Array(repeating: samples.last ?? 0.2, count: targetCount - samples.count)
        }

        let stride = Double(samples.count) / Double(targetCount)
        return (0..<targetCount).map { index in
            let start = Int(Double(index) * stride)
            let end = min(samples.count, Int(Double(index + 1) * stride))
            let bucket = samples[start..<max(start + 1, end)]
            return min(1, max(0.08, bucket.reduce(0, +) / Double(bucket.count)))
        }
    }

    private func resolvedURL(from string: String?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        if string.hasPrefix("http") || string.hasPrefix("file://") {
            return URL(string: string)
        }
        return URL(string: "\(AppServer.origin)\(string)")
    }
}

extension VoiceRecorderManager: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopPlayback()
        }
    }
}

// Feature-local AI audio. It never records a file, uploads PCM or changes TRTC.
enum AIFlowTrace {
    enum Event: String {
        case sendTapped, consentShown, consentAccepted, requestStarted, firstDelta
        case requestCompleted, requestCancelled, requestFailed
        case holdBegan, holdReleased, holdCancelled, captureStarted, captureFinalized
        case permissionDenied, recognizerUnavailable
    }
    static func record(_ event: Event) {
        #if DEBUG
        // Fixed event names only. No account, token, transcript or model output.
        print("[AIFlow] \(event.rawValue)")
        #endif
    }
}

struct AIVoiceUtterance: Equatable {
    let id = UUID()
    let ownerID: String
    let text: String
}

enum AIVoiceText {
    static func transcript(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000))
    }

    static func spokenReply(_ text: String) -> String {
        // Do not read code fences or Markdown URLs aloud. Keep the chat untouched.
        var result = text.replacingOccurrences(of: "(?s)```.*?```", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "!?\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\s{0,3}[#>]+\\s*|[*_`~]", with: "", options: .regularExpression)
        return String(result.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12000))
    }
}

// A final result, silence timer and maximum-duration timer may race. Only one
// can consume a turn; late callbacks from a cancelled capture are rejected.
struct AIVoiceCapture {
    private(set) var id: UUID?
    private var text = ""

    mutating func begin() -> UUID {
        let id = UUID()
        self.id = id; text = ""
        return id
    }

    mutating func update(_ value: String, id: UUID) -> String? {
        guard self.id == id else { return nil }
        text = AIVoiceText.transcript(value)
        return text
    }

    mutating func consume() -> String? {
        guard id != nil else { return nil }
        let result = text
        cancel()
        return result
    }

    mutating func cancel() { id = nil; text = "" }
}

struct AIHoldInteraction {
    private(set) var isActive = false
    private(set) var isCancelling = false

    mutating func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true; isCancelling = false
        return true
    }
    mutating func move(vertical: Double) { if isActive { isCancelling = vertical < -60 } }
    mutating func finish(cancelled: Bool) -> Bool? {
        guard isActive else { return nil }
        let result = cancelled || isCancelling
        isActive = false; isCancelling = false
        return result
    }
}

@MainActor
final class AIVoiceController: NSObject, ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var conversationEnabled = false
    @Published private(set) var isHoldingToTalk = false
    @Published private(set) var isFinalizingHold = false
    @Published private(set) var transcript = ""
    @Published private(set) var submittedUtterance: AIVoiceUtterance?
    @Published var autoReadReplies = false
    @Published var errorMessage: String?
    @Published private(set) var hintMessage: String?

    private var ownerID: String?
    private var sessionToken: String?
    private var generation = UUID()
    private var readNextReply = false
    private var capture = AIVoiceCapture()
    private var permissionTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var hasInputTap = false
    private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var speech: AVSpeechSynthesizer?
    private var spokenID: ObjectIdentifier?
    private var observers: [NSObjectProtocol] = []
    private let callObserver = CXCallObserver()

    func activate(owner: String?, token: String?) {
        guard ownerID != owner || sessionToken != token || observers.isEmpty else { return }
        deactivate()
        ownerID = owner
        sessionToken = token
        callObserver.setDelegate(self, queue: .main)
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     UIApplication.didEnterBackgroundNotification, .cqimCallInviteDidReceive,
                     .cqimCallAnsweredFromSystem] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if name == AVAudioSession.routeChangeNotification,
                   (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue != AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { return }
                Task { @MainActor [weak self] in self?.stopAll() }
            })
        }
    }

    func deactivate() {
        stopAll()
        ownerID = nil
        sessionToken = nil
        autoReadReplies = false
        submittedUtterance = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        callObserver.setDelegate(nil, queue: nil)
    }

    private var canUseAudio: Bool {
        guard let ownerID, !ownerID.isEmpty, let sessionToken, !sessionToken.isEmpty else { return false }
        return UserDefaults.standard.string(forKey: "current_user_id") == ownerID &&
            AuthTokenStore.shared.token == sessionToken && UIApplication.shared.applicationState == .active &&
            !callObserver.calls.contains(where: { !$0.hasEnded })
    }

    func startConversation() {
        stopAll()
        guard canUseAudio else { errorMessage = "请在前台且无通话时使用 AI 语音"; return }
        conversationEnabled = true
        errorMessage = nil
        hintMessage = nil
        startListening()
    }

    func preparePushToTalk() {
        stopAll()
        guard canUseAudio else { errorMessage = "请在前台且无通话时使用 AI 语音"; return }
        errorMessage = nil
        authorizeSpeech(startCapture: false)
    }

    func beginPushToTalk() {
        AIFlowTrace.record(.holdBegan)
        guard !isPreparing, !isFinalizingHold else { return }
        // Permissions must not silently start recording after the finger lifts.
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            preparePushToTalk()
            return
        }
        stopAll()
        guard canUseAudio else { errorMessage = "请在前台且无通话时使用 AI 语音"; return }
        errorMessage = nil; hintMessage = nil
        isHoldingToTalk = true
        beginCapture()
    }

    func endPushToTalk(cancelled: Bool) {
        guard isHoldingToTalk else { return }
        AIFlowTrace.record(cancelled ? .holdCancelled : .holdReleased)
        if cancelled { stopAll(); hintMessage = "已取消发送"; return }
        isHoldingToTalk = false
        isFinalizingHold = true
        stopAudioInput()
        recognitionRequest?.endAudio()
        limitTask?.cancel(); limitTask = nil
        let id = capture.id
        // Let Speech finalize the trailing syllable, with a bounded fallback to
        // the last transcription. UUID consumption still permits only one send.
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, self?.capture.id == id else { return }
            self?.finishListening()
        }
    }

    private func startListening() {
        guard conversationEnabled, canUseAudio, !isPreparing, !isListening else { return }
        authorizeSpeech(startCapture: true)
    }

    private func authorizeSpeech(startCapture: Bool) {
        isPreparing = true
        let ticket = generation
        permissionTask = Task { [weak self] in
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard let self, !Task.isCancelled, self.generation == ticket else { return }
            guard authorization == .authorized else {
                AIFlowTrace.record(.permissionDenied)
                self.fail("请在系统设置中允许语音识别权限"); return
            }
            guard await self.waitForForeground(ticket: ticket) else { return }
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled, self.generation == ticket else { return }
            guard microphone else {
                AIFlowTrace.record(.permissionDenied)
                self.fail("请在系统设置中允许麦克风权限"); return
            }
            guard await self.waitForForeground(ticket: ticket) else { return }
            if startCapture { self.beginCapture() }
            else { self.isPreparing = false; self.hintMessage = "已准备好，请再次按住说话" }
        }
    }

    private func waitForForeground(ticket: UUID) async -> Bool {
        // System permission sheets temporarily make the scene inactive. Do not
        // start audio until foreground activation, nor leave permission state stuck.
        for _ in 0..<20 {
            guard !Task.isCancelled, generation == ticket else { return false }
            if canUseAudio { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if generation == ticket { stopAll() }
        return false
    }

    private func beginCapture() {
        guard canUseAudio, conversationEnabled || isHoldingToTalk else { stopAll(); return }
        let locale = Locale(identifier: AppLanguage.current.resolvedIdentifier == "zh-Hans" ? "zh-CN" : "en-US")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            AIFlowTrace.record(.recognizerUnavailable)
            fail("此设备或语言暂不支持本机语音识别，请使用文字输入")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            previousAudio = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                fail("麦克风暂不可用，请重试")
                return
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.taskHint = .dictation
            recognitionRequest = request
            self.recognizer = recognizer
            let id = capture.begin()
            transcript = ""
            isPreparing = false
            isListening = true
            // The real-time audio callback only appends to Apple's recognition
            // request. No UI/model access, logging, file IO or network work here.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
                request.append(buffer)
            }
            hasInputTap = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in self?.recognized(text: text, final: final, failed: failed, id: id) }
            }
            engine.prepare()
            try engine.start()
            AIFlowTrace.record(.captureStarted)
            limitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, self?.capture.id == id else { return }
                if self?.isHoldingToTalk == true { self?.fail("每次语音最长 45 秒，请重新说") }
                else { self?.finishListening() }
            }
        } catch { fail("麦克风暂不可用，请重试") }
    }

    private func recognized(text: String?, final: Bool, failed: Bool, id: UUID) {
        guard capture.id == id else { return }
        guard canUseAudio else { stopAll(); return }
        if let text, let next = capture.update(text, id: id) {
            if next != transcript {
                transcript = next
                if conversationEnabled { silenceTask?.cancel() }
                if conversationEnabled && !next.isEmpty {
                    silenceTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(1500))
                        guard !Task.isCancelled, self?.capture.id == id else { return }
                        self?.finishListening()
                    }
                }
            }
        }
        // A final recognition result is not permission to send a held gesture.
        if final && !isHoldingToTalk { finishListening() }
        else if failed {
            if isFinalizingHold, !transcript.isEmpty { finishListening() }
            else { fail("语音识别中断，请重试") }
        }
    }

    func finishListening() {
        guard isListening, let text = capture.consume() else { return }
        let owner = ownerID
        let allowed = canUseAudio && (conversationEnabled || isHoldingToTalk || isFinalizingHold)
        let shouldRead = isHoldingToTalk || isFinalizingHold
        stopCapture()
        guard allowed, let owner, !text.isEmpty else { fail("未识别到语音，请重试"); return }
        AIFlowTrace.record(.captureFinalized)
        readNextReply = shouldRead
        submittedUtterance = AIVoiceUtterance(ownerID: owner, text: text)
    }

    func receiveReply(_ text: String) {
        guard (autoReadReplies || conversationEnabled || readNextReply), canUseAudio else { return }
        readNextReply = false
        stopCapture()
        stopSpeech()
        let text = AIVoiceText.spokenReply(text)
        guard !text.isEmpty else { if conversationEnabled { startListening() }; return }
        let synthesizer: AVSpeechSynthesizer
        if let speech { synthesizer = speech }
        else {
            synthesizer = AVSpeechSynthesizer()
            // The system owns TTS audio; do not reconfigure CallKit/TRTC's session.
            synthesizer.usesApplicationAudioSession = false
            synthesizer.delegate = self
            speech = synthesizer
        }
        let utterance = AVSpeechUtterance(string: text)
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)
        let language = detected == .simplifiedChinese || detected == .traditionalChinese ? "zh-CN" :
            detected?.rawValue ?? (AppLanguage.current.resolvedIdentifier == "zh-Hans" ? "zh-CN" : "en-US")
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        spokenID = ObjectIdentifier(utterance)
        isSpeaking = true
        isPaused = false
        synthesizer.speak(utterance)
    }

    func togglePause() {
        guard isSpeaking else { return }
        if isPaused { isPaused = !(speech?.continueSpeaking() ?? false) }
        else { isPaused = speech?.pauseSpeaking(at: .immediate) ?? false }
    }

    func stopAll() {
        generation = UUID()
        permissionTask?.cancel(); permissionTask = nil
        conversationEnabled = false
        readNextReply = false
        stopCapture()
        stopSpeech()
        transcript = ""
        hintMessage = nil
    }

    private func fail(_ message: String) { stopAll(); errorMessage = message }

    private func stopCapture() {
        capture.cancel()
        silenceTask?.cancel(); silenceTask = nil
        limitTask?.cancel(); limitTask = nil
        stopAudioInput()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil; recognitionRequest = nil; recognizer = nil; engine = nil
        isListening = false; isPreparing = false; isHoldingToTalk = false; isFinalizingHold = false
    }

    private func stopAudioInput() {
        engine?.stop()
        if hasInputTap { engine?.inputNode.removeTap(onBus: 0); hasInputTap = false }
        engine = nil
        if let previousAudio {
            self.previousAudio = nil
            // A newly ringing/accepted call owns the session now. Never deactivate it.
            if !callObserver.calls.contains(where: { !$0.hasEnded }) {
                let session = AVAudioSession.sharedInstance()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                try? session.setCategory(previousAudio.0, mode: previousAudio.1, options: previousAudio.2)
            }
        }
    }

    private func stopSpeech() {
        spokenID = nil
        speech?.stopSpeaking(at: .immediate)
        isSpeaking = false; isPaused = false
    }

    private func finishedSpeech(_ id: ObjectIdentifier) {
        guard spokenID == id else { return }
        spokenID = nil
        isSpeaking = false; isPaused = false
        if conversationEnabled, canUseAudio { startListening() }
    }
}

extension AIVoiceController: AVSpeechSynthesizerDelegate, CXCallObserverDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishedSpeech(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard self?.spokenID == id else { return }
            self?.stopAll()
        }
    }
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let active = !call.hasEnded
        Task { @MainActor [weak self] in if active { self?.stopAll() } }
    }
}
