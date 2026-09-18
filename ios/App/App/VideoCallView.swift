import SwiftUI

struct VideoCallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: VideoCallViewModel
    @ObservedObject private var trtc = TRTCManager.shared
    @ObservedObject private var pip = PiPManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var localPreviewOffset: CGSize = .zero
    @State private var localPreviewDrag: CGSize = .zero

    init(session: VideoCallSession) {
        _viewModel = StateObject(wrappedValue: VideoCallViewModel(session: session))
    }

    var body: some View {
        ZStack {
            DoveTheme.ink.ignoresSafeArea()

            if pip.isAppFloatingActive {
                floatingCallWindow
            } else {
                if viewModel.session.callType == .video {
                    videoStage
                } else {
                    audioStage
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    statusPanel
                    controlBar
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            viewModel.startIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if pip.isSystemPiPActive && (newPhase == .inactive || newPhase == .background) {
                pip.handleAppWillResignActive()
            }
        }
        .onChange(of: viewModel.session.status) { _, status in
            guard status == .ended || status == .rejected else { return }
            pip.exitAppFloating()
            pip.stopSystemPiP()
            dismiss()
        }
        .onDisappear {
            if viewModel.session.status != .ended && viewModel.session.status != .rejected {
                viewModel.endCall()
            }
        }
    }

    private var videoStage: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                if let peer = remoteVideoParticipant {
                    TRTCVideoCanvas(role: .remote(peer.id))
                        .ignoresSafeArea()

                    localPreview
                        .frame(width: min(132, proxy.size.width * 0.34), height: min(184, proxy.size.height * 0.24))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                        .padding(.top, 82)
                        .padding(.trailing, 18)
                        .offset(
                            x: localPreviewOffset.width + localPreviewDrag.width,
                            y: localPreviewOffset.height + localPreviewDrag.height
                        )
                        .gesture(localPreviewDragGesture)
                } else {
                    fullScreenLocalPreview
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .onChange(of: hasRemoteVideo) { _, hasRemoteVideo in
            if !hasRemoteVideo {
                localPreviewOffset = .zero
                localPreviewDrag = .zero
            }
        }
    }

    private var fullScreenLocalPreview: some View {
        ZStack {
            TRTCVideoCanvas(role: .local)
                .ignoresSafeArea()

            if trtc.isCameraOff {
                Color.black
                VStack(spacing: 12) {
                    DoveAvatar(name: "我", size: 104)
                    Text(trtc.isMuted ? "已静音" : "我")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                }
            }
        }
    }

    private var localPreview: some View {
        ZStack {
            TRTCVideoCanvas(role: .local)

            if trtc.isCameraOff || viewModel.session.callType == .audio {
                Color.black
                VStack(spacing: 8) {
                    DoveAvatar(name: "我", size: 44)
                    Text(trtc.isMuted ? "已静音" : "我")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.86))
                }
            }

            VolumeRing(volume: trtc.localVolume)
                .padding(8)
        }
    }

    private var audioStage: some View {
        VStack(spacing: 18) {
            Spacer()
            DoveAvatar(name: viewModel.session.peerName, url: viewModel.session.peerAvatar, size: 132)
                .overlay(VolumeRing(volume: trtc.remoteParticipants.first?.volume ?? 0).padding(-10))
            Text(viewModel.session.peerName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
            Text(viewModel.statusText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                enterFloatingMode()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.12), in: Circle())
            }

            Spacer()

            VStack(spacing: 3) {
                Text(callHeaderTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(callHeaderSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.66))
            }

            Spacer()

            if hasRemoteVideo {
                Button {
                    pip.enterAppFloating()
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.12), in: Circle())
                }
            } else {
                Color.clear
                    .frame(width: 40, height: 40)
            }
        }
    }

    @ViewBuilder
    private var statusPanel: some View {
        if viewModel.session.isIncoming && viewModel.session.status == .ringing {
            VStack(spacing: 14) {
                Text("\(viewModel.session.peerName) 邀请你进行\(viewModel.session.callType.title)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                HStack(spacing: 54) {
                    CallRoundButton(title: "拒绝", systemName: "phone.down.fill", color: .red) {
                        viewModel.rejectIncomingCall()
                        dismiss()
                    }
                    CallRoundButton(title: "接听", systemName: "phone.fill", color: DoveTheme.green) {
                        viewModel.acceptIncomingCall()
                    }
                }
            }
            .padding(.bottom, 18)
        } else if viewModel.session.status == .failed, let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.red.opacity(0.8), in: Capsule())
                .padding(.bottom, 12)
        } else if let mediaWarning = trtc.mediaWarning {
            Text(mediaWarning)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.62), in: Capsule())
                .padding(.bottom, 12)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 18) {
            CallControlButton(title: trtc.isMuted ? "取消静音" : "静音", systemName: trtc.isMuted ? "mic.slash.fill" : "mic.fill", isActive: trtc.isMuted) {
                viewModel.toggleMute()
            }

            if !hasConnectedRemote {
                if viewModel.session.callType == .video {
                    CallControlButton(title: "翻转", systemName: "camera.rotate.fill") {
                        viewModel.switchCamera()
                    }
                }
            } else {
                if viewModel.session.callType == .video {
                    CallControlButton(title: trtc.isCameraOff ? "开摄像头" : "关摄像头", systemName: trtc.isCameraOff ? "video.slash.fill" : "video.fill", isActive: trtc.isCameraOff) {
                        viewModel.toggleCamera()
                    }
                }

                CallControlButton(title: trtc.isSpeakerOn ? "扬声器" : "听筒", systemName: trtc.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.fill", isActive: trtc.isSpeakerOn) {
                    viewModel.toggleSpeaker()
                }

                if viewModel.session.callType == .video {
                    CallControlButton(title: "共享", systemName: "rectangle.on.rectangle", isActive: trtc.isScreenSharing) {
                        viewModel.toggleScreenSharing()
                    }
                }
            }

            CallRoundButton(title: "挂断", systemName: "phone.down.fill", color: .red) {
                viewModel.endCall()
                dismiss()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var floatingCallWindow: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    Button {
                        pip.exitAppFloating()
                        pip.stopSystemPiP()
                    } label: {
                        floatingPreview
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        FloatingControlButton(systemName: trtc.isMuted ? "mic.slash.fill" : "mic.fill", tint: trtc.isMuted ? .orange : .white) {
                            viewModel.toggleMute()
                        }
                        if viewModel.session.callType == .video {
                            FloatingControlButton(systemName: trtc.isCameraOff ? "video.slash.fill" : "video.fill", tint: trtc.isCameraOff ? .orange : .white) {
                                viewModel.toggleCamera()
                            }
                        }
                        FloatingControlButton(systemName: "phone.down.fill", tint: .white, background: .red) {
                            viewModel.endCall()
                            pip.exitAppFloating()
                            pip.stopSystemPiP()
                            dismiss()
                        }
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 34)
            }
        }
    }

    private var floatingPreview: some View {
        ZStack {
            if viewModel.session.callType == .video, let peer = trtc.remoteParticipants.first, peer.hasVideo {
                TRTCVideoCanvas(role: .remote(peer.id))
            } else {
                LinearGradient(
                    colors: [DoveTheme.ink, DoveTheme.green.opacity(0.36)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 6) {
                    DoveAvatar(name: viewModel.session.peerName, url: viewModel.session.peerAvatar, size: 42)
                    Text(viewModel.statusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }
            }

            VStack {
                HStack {
                    Image(systemName: pip.isSystemPiPActive ? "pip.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.36), in: Circle())
                    Spacer()
                }
                Spacer()
            }
            .padding(8)
        }
        .frame(width: viewModel.session.callType == .video ? 132 : 148, height: viewModel.session.callType == .video ? 184 : 104)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 20, y: 10)
    }

    private func enterFloatingMode() {
        guard hasRemoteVideo else { return }
        pip.enterAppFloating()
        if viewModel.session.callType == .video {
            pip.startSystemPiP()
        }
    }

    private var remoteVideoParticipant: TRTCRemoteParticipant? {
        trtc.remoteParticipants.first(where: \.hasVideo)
    }

    private var hasRemoteVideo: Bool {
        remoteVideoParticipant != nil
    }

    private var hasConnectedRemote: Bool {
        if viewModel.session.callType == .video {
            return hasRemoteVideo
        }
        return trtc.remoteParticipants.contains(where: \.hasAudio)
    }

    private var callHeaderTitle: String {
        if !viewModel.session.isIncoming, !hasRemoteVideo, viewModel.session.status != .failed {
            return "正在呼叫 \(viewModel.session.peerName)"
        }
        return viewModel.session.callType.title
    }

    private var callHeaderSubtitle: String {
        if !viewModel.session.isIncoming, !hasRemoteVideo, viewModel.session.status != .failed {
            return "等待对方接听"
        }
        if viewModel.session.status == .failed {
            return "未能接通"
        }
        return viewModel.statusText
    }

    private var localPreviewDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                localPreviewDrag = value.translation
            }
            .onEnded { value in
                localPreviewOffset.width += value.translation.width
                localPreviewOffset.height += value.translation.height
                localPreviewDrag = .zero
            }
    }
}

private struct CallControlButton: View {
    let title: String
    let systemName: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(isActive ? DoveTheme.green.opacity(0.9) : .white.opacity(0.16), in: Circle())
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CallRoundButton: View {
    let title: String
    let systemName: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(color, in: Circle())
                    .shadow(color: color.opacity(0.35), radius: 18, y: 8)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct FloatingControlButton: View {
    let systemName: String
    var tint: Color = .white
    var background: Color = .black.opacity(0.58)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(background, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
    }
}

private struct VolumeRing: View {
    let volume: Int

    var body: some View {
        Circle()
            .stroke(DoveTheme.green.opacity(min(0.9, max(0.12, Double(volume) / 120.0))), lineWidth: volume > 12 ? 3 : 1)
            .scaleEffect(volume > 18 ? 1.05 : 1)
            .animation(.easeOut(duration: 0.18), value: volume)
    }
}
