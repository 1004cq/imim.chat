import Foundation
import Combine

// Publisher fixture only. No audio session, mic, owner messages or network.
// Match the production manager's Published declaration block via runner guard.
@MainActor
final class VoiceRecorderManager: ObservableObject {
    @Published var isRecording = false
    @Published var isCancelling = false
    @Published var isPlaying = false
    @Published var playingMessageId: String?
    @Published var playbackProgress: Double = 0
    @Published var recordingDuration: Double = 0
    @Published var livePower: Double = 0
    @Published var liveWaveform: [Double] = Array(repeating: 0.18, count: 28)
    @Published var errorMessage: String?
}

@main
@MainActor
struct ChatVoiceObservationRegression {
    static var checks = 0
    static func check(_ condition: Bool, _ note: String) {
        precondition(condition, note)
        checks += 1
    }

    static func main() {
        let recorder = VoiceRecorderManager()
        let screen = ChatVoiceRecordingState(recorder: recorder)
        let active = ChatVoicePlaybackState(recorder: recorder, messageId: "a")
        let other = ChatVoicePlaybackState(recorder: recorder, messageId: "b")
        var screenUpdates = 0, activeUpdates = 0, otherUpdates = 0, oldUpdates = 0
        var subscriptions = Set<AnyCancellable>()
        screen.objectWillChange.sink { screenUpdates += 1 }.store(in: &subscriptions)
        active.objectWillChange.sink { activeUpdates += 1 }.store(in: &subscriptions)
        other.objectWillChange.sink { otherUpdates += 1 }.store(in: &subscriptions)
        recorder.objectWillChange.sink { oldUpdates += 1 }.store(in: &subscriptions)
        check(screen.recorder === recorder, "same audio owner, no replacement recorder")
        recorder.playingMessageId = "a"
        recorder.isPlaying = true
        check(active.value.isPlaying && other.value == .idle, "only chosen row starts")
        activeUpdates = 0; otherUpdates = 0; screenUpdates = 0; oldUpdates = 0
        for tick in 1...500 { recorder.playbackProgress = Double(tick) / 501 }
        check(activeUpdates == 500, "active voice publishes each changed progress")
        check(otherUpdates == 0, "inactive voice suppresses playback ticks")
        check(screenUpdates == 0, "whole chat does not receive playback ticks")
        check(oldUpdates == 500, "old broad recorder observation comparison")
        print("Synthetic 500 playback ticks: old broad publisher 500, chat projection \(screenUpdates), inactive voice \(otherUpdates), active voice \(activeUpdates)")
        let oldActiveCount = activeUpdates
        recorder.playbackProgress = recorder.playbackProgress
        check(activeUpdates == oldActiveCount, "duplicate progress suppressed")
        recorder.isPlaying = false
        recorder.playingMessageId = "b"
        recorder.isPlaying = true
        check(active.value == .idle && other.value.isPlaying, "switching resets old and activates new row")
        recorder.playbackProgress = 0.25
        check(other.value.progress == 0.25 && active.value.progress == 0, "new progress stays local")
        recorder.isPlaying = false; recorder.playingMessageId = nil; recorder.playbackProgress = 0
        check(active.value == .idle && other.value == .idle, "stop resets all voice presentation")
        check(screenUpdates == 0, "switch/stop still does not invalidate chat")
        let joined = ChatVoicePlaybackState(recorder: recorder, messageId: "a")
        check(joined.value == .idle, "newly appearing inactive voice starts idle")
        recorder.playingMessageId = "a"; recorder.isPlaying = true; recorder.playbackProgress = 0.4
        let joiningActive = ChatVoicePlaybackState(recorder: recorder, messageId: "a")
        check(joiningActive.value == active.value, "appearing voice receives current progress")
        let playbackCount = activeUpdates
        recorder.isRecording = true
        recorder.isCancelling = true
        recorder.recordingDuration = 1
        recorder.liveWaveform = [0.2, 0.8]
        recorder.errorMessage = "fixture error"
        check(screenUpdates == 2, "recording start/error changes still reach owner UI")
        check(activeUpdates == playbackCount, "recording does not invalidate playback")
        screenUpdates = 0
        for tick in 1...500 {
            recorder.recordingDuration = Double(tick) / 20
            recorder.livePower = Double(tick) / 500
            recorder.liveWaveform = [Double(tick) / 500, 0.8]
        }
        check(screenUpdates == 0, "recording meter ticks stay inside recording overlay")
        print("Synthetic 500 recording ticks / 1500 field writes: chat projection \(screenUpdates) updates; overlay reads existing manager directly")
        recorder.livePower = 0.9
        recorder.recordingDuration = recorder.recordingDuration
        recorder.errorMessage = "fixture error"
        check(screenUpdates == 0, "unused power and duplicate fields suppressed")
        recorder.errorMessage = nil
        check(screenUpdates == 1, "alert dismissal reaches owner UI")
        recorder.isRecording = false
        check(screenUpdates == 2, "recording end removes overlay")
        weak var releasedOwner: ChatVoiceRecordingState?
        weak var releasedPlayback: ChatVoicePlaybackState?
        do {
            let temporary = ChatVoiceRecordingState(recorder: recorder)
            let temporaryVoice = ChatVoicePlaybackState(recorder: recorder, messageId: "c")
            releasedOwner = temporary; releasedPlayback = temporaryVoice
        }
        check(releasedOwner == nil && releasedPlayback == nil, "subscriptions do not retain UI projections")
        for animating in [false, true] {
            for motion in [false, true] {
                let first = ChatVoiceWaveformClock.phase(at: Date(timeIntervalSinceReferenceDate: 0.02), isAnimating: animating, reduceMotion: motion)
                let later = ChatVoiceWaveformClock.phase(at: Date(timeIntervalSinceReferenceDate: 0.2), isAnimating: animating, reduceMotion: motion)
                check(first.isFinite && later.isFinite, "bounded waveform phase")
                if animating && !motion {
                    check(first != later && first >= 0 && later < .pi * 2, "active waveform advances without stored animation")
                } else {
                    check(first == 0 && later == 0, "stopped/reduced-motion waveform stays still")
                }
            }
        }
        print("PASS: \(checks) actual production voice projection checks; strict Swift 6. Publisher fixture is not AVAudioPlayer/device verification.")
    }
}
