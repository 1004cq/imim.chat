import AVFoundation
import AVKit
import Combine
import SwiftUI

extension Notification.Name {
    static let imimCameraWillYieldToCall = Notification.Name("IMIMCameraWillYieldToCall")
}

enum CameraCaptureResult {
    case photo(Data)
    case video(URL)

    func discard() {
        if case .video(let url) = self { try? FileManager.default.removeItem(at: url) }
    }
}

/// AVSampleBufferVideoRenderer accepts frames on the capture queue. View/layer hierarchy
/// mutations stay on main; no UIImage allocation or main-queue task is needed per frame.
final class DualCameraPreviewSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct DualCameraPreview: UIViewRepresentable {
    let engine: DualCameraCaptureEngine
    func makeUIView(context: Context) -> DualCameraPreviewSurface {
        let view = DualCameraPreviewSurface()
        view.displayLayer.videoGravity = .resizeAspectFill
        engine.bindPreview(view.displayLayer.sampleBufferRenderer)
        return view
    }
    func updateUIView(_ view: DualCameraPreviewSurface, context: Context) {}
}

@MainActor
final class DualCameraViewModel: ObservableObject {
    let engine = DualCameraCaptureEngine()
    @Published private(set) var ready = false
    @Published private(set) var dual = false
    @Published private(set) var recording = false
    @Published private(set) var saving = false
    @Published private(set) var frontIsMain = false
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false
    @Published private(set) var flashMode = CameraFlashMode.off
    @Published private(set) var draft: CameraCaptureResult?
    @Published private(set) var elapsed = 0
    @Published var warning: String?
    private var permissionTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var generation = UUID()

    func start() {
        let token = UUID(); generation = token
        permissionTask?.cancel()
        ready = false; warning = nil; torchAvailable = false; torchOn = false; flashMode = .off
        permissionTask = Task { [weak self] in
            guard let self else { return }
            guard TRTCManager.shared.canStartCameraCapture else {
                warning = DualCameraFailure.busy.localizedDescription; return
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled, generation == token else { return }
            guard allowed else { warning = DualCameraFailure.permission.localizedDescription; return }
            engine.observeTorch { [weak self] available, on, mode, failure in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.torchAvailable = available; self.torchOn = on
                    self.flashMode = mode
                    if let failure { self.warning = failure.localizedDescription }
                }
            }
            engine.start { [weak self] running, dual, failure in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.ready = running; self.dual = dual
                    self.warning = failure?.localizedDescription
                    self.engine.refreshTorchState()
                }
            }
        }
    }

    func swap() {
        guard dual, ready, !saving else { return }
        frontIsMain.toggle(); engine.setFrontMain(frontIsMain)
    }

    func selectFlashMode(_ mode: CameraFlashMode) {
        guard ready, torchAvailable || mode == .off, draft == nil, !saving, !recording else { return }
        engine.setFlashMode(mode)
    }

    func takePhoto() {
        guard ready, !saving, !recording else { return }
        saving = true
        let token = generation
        engine.takePhoto { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.saving = false
                switch result {
                case .success(let data): self.draft = .photo(data); self.ready = false; self.engine.stop()
                case .failure(let error): self.warning = error.localizedDescription
                }
            }
        }
    }

    func toggleRecording() {
        if recording {
            saving = true; recording = false; durationTask?.cancel(); engine.stopRecording(); return
        }
        guard ready, !saving else { return }
        let token = generation
        saving = true
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled, generation == token else { return }
            guard allowed else { saving = false; warning = DualCameraFailure.permission.localizedDescription; return }
            saving = false; recording = true; elapsed = 0
            engine.startRecording { [weak self] result in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else {
                        if case .success(let url) = result { CameraCaptureResult.video(url).discard() }; return
                    }
                    self.durationTask?.cancel(); self.recording = false; self.saving = false
                    switch result {
                    case .success(let url): self.draft = .video(url); self.ready = false; self.engine.stop()
                    case .failure(let error): self.warning = error.localizedDescription
                    }
                }
            }
            durationTask = Task { [weak self] in
                for second in 1...60 {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, generation == token, recording else { return }
                    elapsed = second
                }
                self?.toggleRecording()
            }
        }
    }

    func retake() {
        draft?.discard(); draft = nil; start()
    }

    func consume() -> CameraCaptureResult? {
        defer { draft = nil }
        return draft
    }

    func stop() {
        generation = UUID(); permissionTask?.cancel(); durationTask?.cancel()
        ready = false; recording = false; saving = false
        torchAvailable = false; torchOn = false; flashMode = .off
        draft?.discard(); draft = nil
        engine.stop()
    }
}

struct DualCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DualCameraViewModel()
    @State private var isVideo = false
    @State private var insetPosition = CGPoint(x: 0.73, y: 0.32)
    let allowsVideo: Bool
    let onCapture: (CameraCaptureResult) -> Void

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                preview
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .onAppear { updateInset(in: geometry.size) }
                    .onChange(of: geometry.size) { _, size in updateInset(in: size) }
            }
            .ignoresSafeArea(.container)

            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(.container)
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                HStack {
                    Button { model.stop(); dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(AppLocalization.string("关闭"))
                    Spacer()
                    Menu {
                        ForEach(CameraFlashMode.allCases, id: \.self) { mode in
                            Button { model.selectFlashMode(mode) } label: {
                                if mode == model.flashMode { Label(flashTitle(mode), systemImage: "checkmark") }
                                else { Text(flashTitle(mode)) }
                            }
                            .disabled(mode != .off && !model.torchAvailable)
                        }
                    } label: {
                        HStack(spacing: 1) {
                            Image(systemName: model.flashMode == .off ? "bolt.slash.fill" : "bolt.fill")
                            if model.flashMode == .automatic { Text("A").font(.system(size: 10, weight: .heavy)) }
                        }
                        .foregroundStyle(model.torchOn || model.flashMode == .on ? .yellow : .white)
                    }
                    .disabled(!model.ready || model.draft != nil || model.saving || model.recording)
                    .opacity(model.torchAvailable ? 1 : 0.45)
                    .accessibilityLabel(AppLocalization.string("闪光灯"))
                    .accessibilityValue(flashTitle(model.flashMode))
                    Button { model.swap() } label: { Image(systemName: "camera.rotate") }
                        .disabled(!model.dual || model.draft != nil || model.saving)
                        .accessibilityLabel(AppLocalization.string("切换主画面"))
                }
                .font(.title3.weight(.semibold))
                .buttonStyle(CameraToolbarButtonStyle())
                .overlay {
                    Text(AppLocalization.string(model.dual ? "前后双摄" : "相机"))
                        .font(.headline).lineLimit(1)
                        .padding(.horizontal, 104)
                        .allowsHitTesting(false)
                }
                if model.recording {
                    Text(String(format: "00:%02d", model.elapsed))
                        .monospacedDigit().font(.headline).padding(8)
                        .background(.red, in: Capsule())
                }

                Spacer(minLength: 20)

                if let warning = model.warning {
                    Text(warning).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                controls
            }
            .padding(.horizontal, 20)
            .padding(.top, 8).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { model.start() }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .imimCameraWillYieldToCall)) { _ in
            // Incoming CallKit sessions must release this composer before TRTC opens its camera.
            model.stop(); dismiss()
        }
    }

    @ViewBuilder private var preview: some View {
        if case .photo(let data) = model.draft, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if case .video(let url) = model.draft {
            CameraMovieReview(url: url)
        } else {
            DualCameraPreview(engine: model.engine)
                .overlay {
                    if !model.ready { ProgressView().tint(.white).allowsHitTesting(false) }
                }
                .overlay {
                    GeometryReader { proxy in
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 6).onChanged { value in
                                guard model.dual else { return }
                                insetPosition = CGPoint(x: value.location.x / max(1, proxy.size.width),
                                                        y: value.location.y / max(1, proxy.size.height))
                                updateInset(in: proxy.size)
                            })
                    }
                }
        }
    }

    private func updateInset(in viewport: CGSize) {
        let point = CGPoint(x: insetPosition.x * viewport.width, y: insetPosition.y * viewport.height)
        model.engine.setInsetCenter(DualCameraGeometry.captureCenter(for: point, viewport: viewport))
    }

    private func flashTitle(_ mode: CameraFlashMode) -> String {
        switch mode {
        case .off: return AppLocalization.string("闪光灯关闭")
        case .automatic: return AppLocalization.string("闪光灯自动")
        case .on: return AppLocalization.string("闪光灯开启")
        }
    }

    @ViewBuilder private var controls: some View {
        if model.draft != nil {
            HStack(spacing: 24) {
                Button(AppLocalization.string("重拍")) { model.retake() }.buttonStyle(.bordered)
                Button(AppLocalization.string("使用拍摄内容")) {
                    guard let result = model.consume() else { return }
                    onCapture(result); dismiss()
                }.buttonStyle(.borderedProminent).tint(DoveTheme.green)
            }.controlSize(.large)
        } else {
            HStack(spacing: 32) {
                if allowsVideo {
                    Button(AppLocalization.string(isVideo ? "照片" : "视频")) { isVideo.toggle() }
                        .disabled(model.recording || model.saving)
                        .frame(minWidth: 64, minHeight: 44)
                }
                Button {
                    if isVideo { model.toggleRecording() } else { model.takePhoto() }
                } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.7), lineWidth: 4).frame(width: 78, height: 78)
                        if model.saving { ProgressView().tint(.white) }
                        else {
                            RoundedRectangle(cornerRadius: model.recording ? 8 : 34)
                                .fill(isVideo ? .red : .white)
                                .frame(width: model.recording ? 32 : 66, height: model.recording ? 32 : 66)
                        }
                    }
                }
                .disabled((!model.ready && !model.recording) || model.saving)
                .accessibilityLabel(AppLocalization.string(model.recording ? "停止录像" : isVideo ? "开始录像" : "拍照"))
                if allowsVideo { Color.clear.frame(width: 64, height: 44) }
            }
            Text(AppLocalization.string(isVideo ? "最长录制 60 秒" : "拖动画面可移动小窗"))
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct CameraToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 44, height: 44)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.12), in: Circle())
    }
}

private struct CameraMovieReview: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player = AVPlayer(url: url); player?.play() }
            .onDisappear { player?.pause(); player = nil }
    }
}
