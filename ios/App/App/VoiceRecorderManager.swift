import AVFoundation
import Combine
import Foundation

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
        return URL(string: "https://wed.imim.chat\(string)")
    }
}

extension VoiceRecorderManager: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopPlayback()
        }
    }
}
