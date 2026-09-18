import SwiftUI

struct VoiceMessageBubble: View {
    let message: Message
    let isPlaying: Bool
    let progress: Double
    let onTap: () -> Void

    private var durationText: String {
        let duration = Int((message.voiceDuration ?? 0).rounded())
        return "\(max(1, duration))\""
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(message.isOutgoing ? .white.opacity(0.8) : DoveTheme.green.opacity(0.14))
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DoveTheme.green)
                        .offset(x: isPlaying ? 0 : 1)
                }
                .frame(width: 30, height: 30)

                VoiceWaveformView(
                    samples: message.voiceWaveform.isEmpty ? VoiceWaveformView.defaultSamples : message.voiceWaveform,
                    progress: progress,
                    isAnimating: isPlaying,
                    tint: message.isOutgoing ? DoveTheme.ink : DoveTheme.green
                )
                .frame(width: 128, height: 28)

                Text(durationText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DoveTheme.ink.opacity(0.76))
                    .monospacedDigit()
            }
            .padding(.horizontal, DoveTheme.Chat.bubbleHPadding)
            .padding(.vertical, 9)
            .frame(minWidth: 210, alignment: .leading)
            .background(background)
            .overlay(border)
            .clipShape(shape)
            .shadow(color: .black.opacity(message.isOutgoing ? 0.045 : 0.035), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var background: some View {
        Group {
            if message.isOutgoing {
                LinearGradient(
                    colors: [DoveTheme.sentBubble.opacity(0.98), Color(red: 1.0, green: 0.88, blue: 0.40).opacity(0.96)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                DoveTheme.receivedBubble
            }
        }
    }

    private var border: some View {
        shape.stroke(message.isOutgoing ? DoveTheme.sentBubbleEdge.opacity(0.42) : .white.opacity(0.95), lineWidth: 1)
    }

    private var shape: UnevenRoundedRectangle {
        if message.isOutgoing {
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 6, style: .continuous)
        } else {
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 20, bottomTrailingRadius: 20, topTrailingRadius: 20, style: .continuous)
        }
    }
}

struct VoiceWaveformView: View {
    static let defaultSamples: [Double] = [
        0.20, 0.34, 0.48, 0.28, 0.66, 0.44, 0.76, 0.38,
        0.58, 0.86, 0.52, 0.32, 0.62, 0.72, 0.42, 0.30,
        0.54, 0.82, 0.64, 0.38, 0.50, 0.74, 0.46, 0.26,
        0.40, 0.68, 0.58, 0.34, 0.48, 0.72, 0.36, 0.22
    ]

    let samples: [Double]
    let progress: Double
    let isAnimating: Bool
    let tint: Color

    @State private var phase = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isAnimating)) { _ in
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                let spacing: CGFloat = 3
                let barWidth = max(2, (width - spacing * CGFloat(samples.count - 1)) / CGFloat(samples.count))

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(samples.indices, id: \.self) { index in
                        let normalized = max(0.08, min(1, samples[index]))
                        let wave = isAnimating ? 0.16 * sin(Double(index) * 0.72 + phase) : 0
                        let barHeight = max(4, height * CGFloat(max(0.08, min(1, normalized + wave))))
                        let played = Double(index) / Double(max(1, samples.count - 1)) <= progress

                        Capsule()
                            .fill(played ? tint : tint.opacity(0.28))
                            .frame(width: barWidth, height: barHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { phase += 0.5 }
        .onChange(of: isAnimating) { _, newValue in
            if newValue {
                withAnimation(.linear(duration: 0.35).repeatForever(autoreverses: false)) {
                    phase += .pi * 2
                }
            }
        }
    }
}

struct VoiceRecordingOverlay: View {
    let duration: Double
    let waveform: [Double]
    let isCancelling: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isCancelling ? "xmark.circle.fill" : "mic.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(isCancelling ? .red : DoveTheme.green)

            VoiceWaveformView(
                samples: waveform,
                progress: min(1, duration / 60),
                isAnimating: true,
                tint: isCancelling ? .red : DoveTheme.green
            )
            .frame(width: 190, height: 34)

            Text(isCancelling ? "松开取消" : "上滑取消  \(format(duration))")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isCancelling ? .red : DoveTheme.ink)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
    }

    private func format(_ value: Double) -> String {
        String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }
}
