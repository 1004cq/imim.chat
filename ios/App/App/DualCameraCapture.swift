import AVFoundation
import CoreImage
import ImageIO
import UIKit

enum DualCameraFailure: String, LocalizedError {
    case permission = "请在系统设置中允许相机和麦克风权限"
    case busy = "相机正被通话或其他拍摄使用"
    case unavailable = "相机暂时不可用，请关闭其他相机后重试"
    case unsupported = "此设备使用单摄拍摄"
    case pressure = "双摄负载过高，已切换单摄"
    case interrupted = "拍摄已暂停，返回前台后恢复预览"
    case noFrame = "画面尚未准备好，请稍后重试"
    case recording = "录像保存失败，请重试"
    case torchUnavailable = "当前闪光灯不可用"
    case torchFailed = "无法开启闪光灯，请稍后重试"
    var errorDescription: String? { AppLocalization.string(rawValue) }
}

/// One AVCapture owner across composer and custom call capture. No media data is stored here.
/// The lock protects only this synchronous hardware lease, never an async wait.
private enum CameraHardwareLease {
    private static let lock = NSLock()
    private static var owner: UUID?
    private static weak var engine: DualCameraCaptureEngine?
    static func acquire(_ id: UUID, engine: DualCameraCaptureEngine) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil || owner == id else { return false }
        owner = id
        self.engine = engine
        return true
    }
    static func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == id { owner = nil; engine = nil }
    }
    static func current() -> DualCameraCaptureEngine? {
        lock.lock(); defer { lock.unlock() }
        return engine
    }
}

/// Geometry is shared by preview, JPEG, recording and the outgoing TRTC stream.
enum DualCameraGeometry {
    static let size = CGSize(width: 720, height: 1280)
    static let fps: Int32 = 24
    static let insetDiameter: CGFloat = 240

    /// Invert the full-screen aspect-fill crop, then convert top-left UI points
    /// to Core Image's bottom-left coordinates. Keep the entire circle visible.
    static func captureCenter(for point: CGPoint, viewport: CGSize) -> CGPoint {
        guard viewport.width > 0, viewport.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let scale = max(viewport.width / size.width, viewport.height / size.height)
        let radius = insetDiameter * scale / 2
        let horizontalMargin = min(viewport.width / 2, radius + 16)
        let verticalMargin = min(viewport.height / 2, radius + 16)
        let x = min(viewport.width - horizontalMargin, max(horizontalMargin, point.x))
        let y = min(viewport.height - verticalMargin, max(verticalMargin, point.y))
        let offset = CGPoint(x: (viewport.width - size.width * scale) / 2,
                             y: (viewport.height - size.height * scale) / 2)
        return CGPoint(x: (x - offset.x) / scale / size.width,
                       y: 1 - (y - offset.y) / scale / size.height)
    }

    static func insetRect(center: CGPoint) -> CGRect {
        let radius = insetDiameter / 2
        let x = min(size.width - radius - 16, max(radius + 16, center.x * size.width))
        let y = min(size.height - radius - 16, max(radius + 16, center.y * size.height))
        return CGRect(x: x - radius, y: y - radius, width: insetDiameter, height: insetDiameter)
    }

    static func aspectFill(_ extent: CGRect, into target: CGRect) -> CGAffineTransform {
        let scale = max(target.width / max(1, extent.width), target.height / max(1, extent.height))
        return CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: target.midX, y: target.midY))
    }
}

struct DualCameraFrameCadence {
    private var next = CMTime.invalid
    private var lastInput = CMTime.invalid
    mutating func reset() { next = .invalid; lastInput = .invalid }
    mutating func accepts(_ pts: CMTime) -> Bool {
        guard pts.isValid, !pts.isIndefinite else { return false }
        if lastInput.isValid {
            if CMTimeCompare(pts, lastInput) == 0 { return false }
            if CMTimeCompare(pts, lastInput) < 0 { reset() }
        }
        lastInput = pts
        if next.isValid, CMTimeGetSeconds(pts - next) < -0.002 { return false }
        let step = CMTime(value: 1, timescale: DualCameraGeometry.fps)
        next = !next.isValid || CMTimeGetSeconds(pts - next) > 0.2 ? pts + step : next + step
        return true
    }
}

enum CameraFlashMode: String, CaseIterable, Sendable {
    case off, automatic, on
}

/// APEX Bv + 5 approximates EV100. Use exposure metadata as a fallback, and a
/// short median so a single transitional exposure does not decide the capture.
/// Sample only while the rear torch is off; freeze the decision for a recording
/// instead of using the illuminated scene to repeatedly turn the light off/on.
struct CameraAutoFlashPolicy {
    private var samples: [Double] = []
    private var sampledAt: TimeInterval?
    mutating func reset() { samples.removeAll(keepingCapacity: true); sampledAt = nil }

    mutating func record(brightnessValue: Double?, aperture: Double, shutterSeconds: Double,
                         iso: Double, at time: TimeInterval) {
        guard time.isFinite else { return }
        let ev: Double
        if let brightnessValue, brightnessValue.isFinite { ev = brightnessValue + 5 }
        else {
            guard aperture.isFinite, aperture > 0, shutterSeconds.isFinite, shutterSeconds > 0,
                  iso.isFinite, iso > 0 else { return }
            ev = log2(aperture * aperture / shutterSeconds) - log2(iso / 100)
        }
        guard ev.isFinite else { return }
        if let sampledAt, time < sampledAt || time - sampledAt > 1 { reset() }
        samples.append(ev)
        if samples.count > 5 { samples.removeFirst() }
        sampledAt = time
    }

    func needsLight(at time: TimeInterval) -> Bool? {
        guard time.isFinite, let sampledAt, time >= sampledAt, time - sampledAt <= 1, !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2] < 5
    }
}

/// Rotation is camera-specific: newer front sensors may already be portrait.
/// Normalize before cropping/mirroring so preview, photos, movies and calls share pixels.
struct DualCameraFrameOrientation {
    let clockwiseDegrees: CGFloat
    let mirrored: Bool
    static let identity = DualCameraFrameOrientation(clockwiseDegrees: 0, mirrored: false)

    func upright(_ source: CIImage) -> CIImage {
        let angle = clockwiseDegrees.isFinite ? clockwiseDegrees.truncatingRemainder(dividingBy: 360) : 0
        var image = source.transformed(by: CGAffineTransform(rotationAngle: -angle * .pi / 180))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if mirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .concatenating(CGAffineTransform(translationX: image.extent.width, y: 0)))
        }
        return image
    }
}

final class DualCameraCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var pool: CVPixelBufferPool?

    init() {
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, [
            kCVPixelBufferWidthKey: Int(DualCameraGeometry.size.width),
            kCVPixelBufferHeightKey: Int(DualCameraGeometry.size.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pool)
    }

    func compose(main: CVPixelBuffer, inset: CVPixelBuffer?, center: CGPoint,
                 mainOrientation: DualCameraFrameOrientation = .identity,
                 insetOrientation: DualCameraFrameOrientation = .identity) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        // AVAssetWriter/TRTC may retain buffers. Bound allocations instead of growing per frame.
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }
        let bounds = CGRect(origin: .zero, size: DualCameraGeometry.size)
        let mainImage = mainOrientation.upright(CIImage(cvPixelBuffer: main))
        var result = mainImage.transformed(by: DualCameraGeometry.aspectFill(mainImage.extent, into: bounds)).cropped(to: bounds)
        if let inset {
            let rect = DualCameraGeometry.insetRect(center: center)
            let foreground = insetOrientation.upright(CIImage(cvPixelBuffer: inset))
            let fitted = foreground.transformed(by: DualCameraGeometry.aspectFill(foreground.extent, into: rect)).cropped(to: rect)
            // A hard circular mask with a narrow antialiased edge; transparent outside.
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: rect.midX, y: rect.midY),
                "inputRadius0": rect.width / 2 - 1,
                "inputRadius1": rect.width / 2,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear
            ])!.outputImage!.cropped(to: bounds)
            result = fitted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask
            ]).cropped(to: bounds)
        }
        context.render(result, to: output, bounds: bounds, colorSpace: colorSpace)
        return output
    }

    func jpeg(_ buffer: CVPixelBuffer) -> Data? {
        context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: colorSpace,
                                   options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    }
}

/// All session, frame, writer and callback state is confined to `queue`.
/// @unchecked bridges AVFoundation's delegate API (not Sendable in Swift 5 SDKs).
/// UI callbacks hop to main; no live SwiftData objects cross this boundary.
final class DualCameraCaptureEngine: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    typealias StateHandler = @Sendable (Bool, Bool, DualCameraFailure?) -> Void
    private let queue = DispatchQueue(label: "chat.imim.dual-camera", qos: .userInitiated)
    private let leaseID = UUID()
    private var session: AVCaptureSession?
    private var rearOutput: AVCaptureVideoDataOutput?
    private var frontOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var rearOrientation = DualCameraFrameOrientation.identity
    private var frontOrientation = DualCameraFrameOrientation.identity
    private var frontFrame: CVPixelBuffer?
    private var frontPTS = CMTime.invalid
    private var lastFrame: CVPixelBuffer?
    private var lastPTS = CMTime.invalid
    private var cadence = DualCameraFrameCadence()
    private var frontIsMain = false
    private var center = CGPoint(x: 0.75, y: 0.72)
    private var dual = false
    private var desiredRunning = false
    private var backgrounded = false
    private var observerTokens: [NSObjectProtocol] = []
    private let compositor = DualCameraCompositor()
    private var preview: AVSampleBufferVideoRenderer?
    private var stateHandler: StateHandler?
    private var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?
    private var recorder: DualCameraMovieWriter?
    private var recordingResult: (@Sendable (Result<URL, Error>) -> Void)?
    private var ownsRecordingAudio = false
    private var pressureObservers: [NSKeyValueObservation] = []
    private var runtimeRecoveryAttempted = false
    private var torchObservers: [NSKeyValueObservation] = []
    private var torchHandler: (@Sendable (Bool, Bool, CameraFlashMode, DualCameraFailure?) -> Void)?
    private var flashMode = CameraFlashMode.off
    private var autoFlash = CameraAutoFlashPolicy()
    private var torchActivatedAt: TimeInterval = 0
    private var recordingLightReadyAt: TimeInterval = 0
    private struct PendingPhoto {
        let id: UUID
        let readyAt: TimeInterval
        let completion: @Sendable (Result<Data, Error>) -> Void
    }
    private var pendingPhoto: PendingPhoto?
    #if DEBUG
    private var rearFrames = 0
    private var frontFrames = 0
    private var composedFrames = 0
    private var lastDiagnosticTime: TimeInterval = 0
    #endif

    @MainActor static func yieldToCall() async {
        let current = CameraHardwareLease.current()
        if let current {
            await withCheckedContinuation { continuation in
                current.queue.async {
                    // CallKit may already own activation. Remove the recording mic without
                    // deactivating the shared audio session underneath the new call.
                    current.ownsRecordingAudio = false
                    current.desiredRunning = false
                    current.finishRecording(); current.tearDown()
                    continuation.resume()
                }
            }
        }
        NotificationCenter.default.post(name: .imimCameraWillYieldToCall, object: nil)
    }

    func start(onState: @escaping StateHandler, onFrame: ((CVPixelBuffer, CMTime) -> Void)? = nil) {
        queue.async { [self] in
            guard CameraHardwareLease.acquire(leaseID, engine: self) else { onState(false, false, .busy); return }
            stateHandler = onState; frameHandler = onFrame
            desiredRunning = true
            runtimeRecoveryAttempted = false
            installObservers()
            do {
                try configure(preferDual: true)
                session?.startRunning()
                stateHandler?(session?.isRunning == true, dual, dual ? nil : .unsupported)
            } catch {
                tearDown()
                onState(false, false, .unavailable)
            }
        }
    }

    func stop(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            desiredRunning = false
            finishRecording()
            tearDown()
            completion?()
        }
    }

    func bindPreview(_ renderer: AVSampleBufferVideoRenderer) { queue.async { self.preview = renderer } }
    func setFrontMain(_ value: Bool) { queue.async { self.frontIsMain = value } }
    func setInsetCenter(_ value: CGPoint) { queue.async { self.center = value } }

    func observeTorch(_ handler: @escaping @Sendable (Bool, Bool, CameraFlashMode, DualCameraFailure?) -> Void) {
        queue.async { self.torchHandler = handler; self.publishTorchState() }
    }

    func refreshTorchState() { queue.async { self.publishTorchState() } }

    func setFlashMode(_ mode: CameraFlashMode) {
        queue.async { [self] in
            guard pendingPhoto == nil, recorder == nil else { return }
            do {
                try applyTorch(mode == .on)
                flashMode = mode
                autoFlash.reset()
            } catch {
                publishTorchState(failure: .torchFailed); return
            }
            publishTorchState()
        }
    }

    private func applyTorch(_ enabled: Bool) throws {
        guard desiredRunning, !backgrounded, session?.isRunning == true,
              let device = rearCameraDevice, device.hasTorch,
              device.isTorchModeSupported(enabled ? .on : .off),
              !enabled || device.isTorchAvailable else { throw DualCameraFailure.torchUnavailable }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if enabled {
            try device.setTorchModeOn(level: 0.5)
            torchActivatedAt = ProcessInfo.processInfo.systemUptime
        } else { device.torchMode = .off; torchActivatedAt = 0 }
    }

    private func prepareAutomaticLight() throws {
        guard flashMode == .automatic else { return }
        guard let needed = autoFlash.needsLight(at: ProcessInfo.processInfo.systemUptime) else { throw DualCameraFailure.noFrame }
        try applyTorch(needed)
        publishTorchState()
    }

    private var rearCameraDevice: AVCaptureDevice? {
        session?.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.position == .back }?.device
    }

    private func publishTorchState(failure: DualCameraFailure? = nil) {
        guard let device = rearCameraDevice else { torchHandler?(false, false, flashMode, failure); return }
        let available = desiredRunning && !backgrounded && session?.isRunning == true &&
            device.hasTorch && device.isTorchModeSupported(.on) && device.isTorchAvailable
        #if DEBUG
        print("[CameraTorch] available=\(available) active=\(device.isTorchActive) mode=\(flashMode.rawValue)")
        #endif
        torchHandler?(available, available && device.isTorchActive, flashMode, failure)
    }

    private func turnTorchOff(resetMode: Bool = true) {
        if resetMode { flashMode = .off }
        torchActivatedAt = 0; autoFlash.reset()
        guard let device = rearCameraDevice, device.hasTorch, device.isTorchModeSupported(.off) else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        } catch { /* Stopping the capture session below also releases the torch hardware. */ }
        publishTorchState()
    }

    private func observeTorchHardware() {
        guard let device = rearCameraDevice else { return }
        torchObservers = [
            device.observe(\.isTorchAvailable, options: [.new]) { [weak self] _, _ in
                self?.queue.async { [weak self] in self?.publishTorchState() }
            },
            device.observe(\.isTorchActive, options: [.new]) { [weak self] _, _ in
                self?.queue.async { [weak self] in self?.publishTorchState() }
            }
        ]
    }

    func takePhoto(_ completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        queue.async { [self] in
            guard desiredRunning, !backgrounded, session?.isRunning == true, lastFrame != nil, pendingPhoto == nil else {
                completion(.failure(DualCameraFailure.noFrame)); return
            }
            do { try prepareAutomaticLight() }
            catch { completion(.failure(error)); return }
            let request = PendingPhoto(id: UUID(), readyAt: max(ProcessInfo.processInfo.systemUptime, torchActivatedAt + 0.25), completion: completion)
            pendingPhoto = request
            queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.pendingPhoto?.id == request.id else { return }
                self.finishPhoto(.failure(DualCameraFailure.noFrame))
            }
        }
    }

    private func finishPhoto(_ result: Result<Data, Error>) {
        guard let pendingPhoto else { return }
        self.pendingPhoto = nil
        if flashMode == .automatic { turnTorchOff(resetMode: false) }
        pendingPhoto.completion(result)
    }

    /// Microphone is added only for user-requested recording. Calls never use this path.
    func startRecording(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            guard recorder == nil, session?.isRunning == true, lastFrame != nil else {
                completion(.failure(DualCameraFailure.noFrame)); return
            }
            do {
                try prepareAutomaticLight()
                recordingLightReadyAt = max(ProcessInfo.processInfo.systemUptime, torchActivatedAt + 0.25)
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
                try audio.setActive(true)
                ownsRecordingAudio = true
                try addMicrophone()
                recorder = try DualCameraMovieWriter()
                recordingResult = completion
            } catch {
                removeMicrophone()
                if flashMode == .automatic { turnTorchOff(resetMode: false) }
                completion(.failure(error))
            }
        }
    }

    func stopRecording() { queue.async { self.finishRecording() } }

    private func configure(preferDual: Bool) throws {
        finishPhoto(.failure(DualCameraFailure.interrupted))
        turnTorchOff()
        torchObservers.removeAll()
        pressureObservers.removeAll()
        session?.stopRunning()
        session = nil; rearOutput = nil; frontOutput = nil; audioOutput = nil
        frontFrame = nil; lastFrame = nil; frontPTS = .invalid; lastPTS = .invalid; cadence.reset()
        dual = false
        if preferDual, AVCaptureMultiCamSession.isMultiCamSupported {
            let candidate = AVCaptureMultiCamSession()
            candidate.automaticallyConfiguresApplicationAudioSession = false
            candidate.beginConfiguration()
            do {
                rearOutput = try addCamera(.back, to: candidate, multi: true)
                frontOutput = try addCamera(.front, to: candidate, multi: true)
                candidate.commitConfiguration()
                if candidate.hardwareCost <= 1, candidate.systemPressureCost <= 1 {
                    session = candidate; dual = true
                    observePressure(in: candidate)
                    observeTorchHardware()
                    return
                }
            } catch { candidate.commitConfiguration() }
            rearOutput = nil; frontOutput = nil
        }
        let fallback = AVCaptureSession()
        fallback.automaticallyConfiguresApplicationAudioSession = false
        fallback.sessionPreset = .hd1280x720
        fallback.beginConfiguration()
        do {
            rearOutput = try addCamera(.back, to: fallback, multi: false)
            fallback.commitConfiguration(); session = fallback
            observeTorchHardware()
        } catch { fallback.commitConfiguration(); throw error }
    }

    private func addCamera(_ position: AVCaptureDevice.Position, to session: AVCaptureSession, multi: Bool) throws -> AVCaptureVideoDataOutput {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw DualCameraFailure.unavailable
        }
        if multi {
            let formats = device.formats.filter {
                let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return $0.isMultiCamSupported && size.width <= 1280 && size.height <= 720 &&
                    $0.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= Double(DualCameraGeometry.fps) && $0.maxFrameRate >= Double(DualCameraGeometry.fps)
                    }
            }
            guard let format = formats.max(by: {
                CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
            }) else { throw DualCameraFailure.unsupported }
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: DualCameraGeometry.fps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: DualCameraGeometry.fps)
            device.unlockForConfiguration()
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw DualCameraFailure.unavailable }
        session.addInputWithNoConnections(input)
        session.addOutputWithNoConnections(output)
        guard let port = input.ports.first(where: { $0.mediaType == .video }) else { throw DualCameraFailure.unavailable }
        let connection = AVCaptureConnection(inputPorts: [port], output: output)
        guard session.canAddConnection(connection) else { throw DualCameraFailure.unavailable }
        session.addConnection(connection)
        // Request native unrotated/unmirrored buffers, including iPad cameras whose
        // connection defaults differ. Apply the camera-specific transform once in CI.
        guard connection.isVideoRotationAngleSupported(0) else { throw DualCameraFailure.unavailable }
        connection.videoRotationAngle = 0
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let angle: CGFloat
        if #available(iOS 27.0, *) {
            // Our shared encoded canvas is portrait, independent of sensor mounting.
            angle = coordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)
        } else {
            angle = coordinator.videoRotationAngleForHorizonLevelCapture
        }
        let orientation = DualCameraFrameOrientation(clockwiseDegrees: angle, mirrored: position == .front)
        if position == .front { frontOrientation = orientation }
        else { rearOrientation = orientation }
        #if DEBUG
        print("[DualCamera] orientation camera=\(position == .front ? "front" : "rear") clockwise=\(angle) mirrored=\(orientation.mirrored)")
        #endif
        return output
    }

    private func addMicrophone() throws {
        guard let session, let device = AVCaptureDevice.default(for: .audio) else { throw DualCameraFailure.permission }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else { throw DualCameraFailure.unavailable }
        session.addInput(input); session.addOutput(output); audioOutput = output
    }

    private func removeMicrophone() {
        if let session, audioOutput != nil {
            session.beginConfiguration()
            if let audioOutput { session.removeOutput(audioOutput) }
            for input in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) where input.device.hasMediaType(.audio) {
                session.removeInput(input)
            }
            session.commitConfiguration(); audioOutput = nil
        }
        if ownsRecordingAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsRecordingAudio = false
        }
    }

    private func finishRecording() {
        if flashMode == .automatic { turnTorchOff(resetMode: false) }
        guard let recorder else { removeMicrophone(); return }
        self.recorder = nil
        let result = recordingResult; recordingResult = nil
        recorder.finish { result?($0) }
        removeMicrophone()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard desiredRunning, !backgrounded else { return }
        if output === audioOutput { recorder?.appendAudio(sampleBuffer); return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output === frontOutput {
            frontFrame = buffer; frontPTS = pts
            #if DEBUG
            frontFrames += 1
            #endif
            return
        }
        guard output === rearOutput else { return }
        let capturedAt = ProcessInfo.processInfo.systemUptime
        if let device = rearCameraDevice, device.torchMode == .off, !device.isTorchActive {
            let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any]
            let brightness = (exif?[kCGImagePropertyExifBrightnessValue as String] as? NSNumber)?.doubleValue
            autoFlash.record(brightnessValue: brightness, aperture: Double(device.lensAperture),
                             shutterSeconds: CMTimeGetSeconds(device.exposureDuration), iso: Double(device.iso), at: capturedAt)
        }
        #if DEBUG
        rearFrames += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastDiagnosticTime >= 5 {
            print("[DualCamera] rear=\(rearFrames) front=\(frontFrames) composed=\(composedFrames) dual=\(dual) recording=\(recorder != nil)")
            lastDiagnosticTime = now
        }
        #endif
        // Resample 30 fps single-camera fallback to 24 fps without dropping every other frame.
        guard cadence.accepts(pts) else { return }
        if dual {
            guard let frontFrame, frontPTS.isValid, abs(CMTimeGetSeconds(pts - frontPTS)) < 0.25 else { return }
            lastFrame = compositor.compose(main: frontIsMain ? frontFrame : buffer,
                                           inset: frontIsMain ? buffer : frontFrame, center: center,
                                           mainOrientation: frontIsMain ? frontOrientation : rearOrientation,
                                           insetOrientation: frontIsMain ? rearOrientation : frontOrientation)
        } else { lastFrame = compositor.compose(main: buffer, inset: nil, center: center,
                                                mainOrientation: rearOrientation) }
        guard let frame = lastFrame else { return }
        lastPTS = pts
        #if DEBUG
        composedFrames += 1
        #endif
        if capturedAt >= recordingLightReadyAt { recorder?.appendVideo(frame, pts: pts) }
        let lightReady = torchActivatedAt == 0 || rearCameraDevice?.isTorchActive == true
        if let pendingPhoto, capturedAt >= pendingPhoto.readyAt, lightReady {
            if let data = compositor.jpeg(frame) { finishPhoto(.success(data)) }
            else { finishPhoto(.failure(DualCameraFailure.noFrame)) }
        }
        frameHandler?(frame, pts)
        if let preview {
            var format: CMVideoFormatDescription?
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format)
            if let format {
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame, formatDescription: format,
                                                        sampleTiming: &timing, sampleBufferOut: &sample)
            }
            if let sample {
                if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
                    attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
                }
                if preview.status == .failed { preview.flush() }
                if preview.isReadyForMoreMediaData { preview.enqueue(sample) }
            }
        }
    }

    private func observePressure(in session: AVCaptureSession) {
        pressureObservers = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.map { input in
            input.device.observe(\.systemPressureState, options: [.new]) { [weak self] _, change in
                guard let level = change.newValue?.level,
                      level == .serious || level == .critical || level == .shutdown else { return }
                self?.queue.async { [weak self] in
                    guard let self, self.dual, self.desiredRunning else { return }
                    self.finishRecording()
                    do {
                        try self.configure(preferDual: false)
                        if !self.backgrounded { self.session?.startRunning() }
                        self.stateHandler?(self.session?.isRunning == true, false, .pressure)
                    } catch { self.stateHandler?(false, false, .unavailable) }
                }
            }
        }
    }

    private func installObservers() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.backgrounded = true; self.finishPhoto(.failure(DualCameraFailure.interrupted))
                self.turnTorchOff(); self.finishRecording(); self.session?.stopRunning()
                self.frontFrame = nil; self.lastFrame = nil
                self.preview?.flush(removingDisplayedImage: true, completionHandler: nil)
                self.stateHandler?(false, self.dual, .interrupted)
            }
        })
        observerTokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.desiredRunning else { return }
                self.backgrounded = false; self.lastPTS = .invalid; self.cadence.reset()
                self.preview?.flush()
                self.session?.startRunning()
                self.stateHandler?(self.session?.isRunning == true, self.dual, self.dual ? nil : .unsupported)
            }
        })
        observerTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] note in
            guard let interruptedSession = note.object as? AVCaptureSession else { return }
            self?.queue.async { [weak self] in
                guard let self, self.session === interruptedSession else { return }
                self.finishPhoto(.failure(DualCameraFailure.interrupted))
                self.turnTorchOff()
                self.finishRecording()
                self.stateHandler?(false, self.dual, .interrupted)
            }
        })
        observerTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: nil) { [weak self] note in
            guard let interruptedSession = note.object as? AVCaptureSession else { return }
            self?.queue.async { [weak self] in
                guard let self, self.session === interruptedSession, self.desiredRunning, !self.backgrounded else { return }
                self.lastPTS = .invalid; self.cadence.reset(); self.frontFrame = nil; self.session?.startRunning()
                self.stateHandler?(self.session?.isRunning == true, self.dual, nil)
            }
        })
        observerTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil) { [weak self] note in
            guard let failed = note.object as? AVCaptureSession else { return }
            self?.queue.async { [weak self] in
                guard let self, self.session === failed, self.desiredRunning else { return }
                self.finishRecording()
                guard !self.runtimeRecoveryAttempted else {
                    let callback = self.stateHandler
                    self.desiredRunning = false; self.tearDown()
                    callback?(false, false, .unavailable)
                    return
                }
                self.runtimeRecoveryAttempted = true
                do {
                    try self.configure(preferDual: false)
                    if !self.backgrounded { self.session?.startRunning() }
                    self.stateHandler?(self.session?.isRunning == true, false, .pressure)
                } catch { self.stateHandler?(false, false, .unavailable) }
            }
        })
    }

    private func tearDown() {
        finishPhoto(.failure(DualCameraFailure.interrupted))
        turnTorchOff()
        torchObservers.removeAll()
        torchHandler?(false, false, .off, nil); torchHandler = nil
        pressureObservers.removeAll()
        session?.stopRunning(); session = nil
        frontFrame = nil; lastFrame = nil; rearOutput = nil; frontOutput = nil
        frameHandler = nil; stateHandler = nil; preview = nil
        observerTokens.forEach(NotificationCenter.default.removeObserver); observerTokens.removeAll()
        CameraHardwareLease.release(leaseID)
    }
}

/// Accessed only by the capture queue until finish() transfers sole ownership to AVAssetWriter.
final class DualCameraMovieWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let url: URL
    private var firstPTS: CMTime?
    private var lastVideoPTS = CMTime.invalid
    private var hasAudio = false
    private var hasVideo = false

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("imim-camera-\(UUID().uuidString).mp4")
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 720, AVVideoHeightKey: 1280,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoExpectedSourceFrameRateKey: 24]
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw DualCameraFailure.recording }
        writer.add(video); writer.add(audio)
    }

    func appendVideo(_ buffer: CVPixelBuffer, pts: CMTime) {
        if firstPTS == nil {
            guard writer.startWriting() else { return }
            firstPTS = pts; writer.startSession(atSourceTime: pts)
        }
        guard writer.status == .writing, video.isReadyForMoreMediaData,
              !lastVideoPTS.isValid || CMTimeCompare(pts, lastVideoPTS) > 0 else { return }
        if adaptor.append(buffer, withPresentationTime: pts) { lastVideoPTS = pts; hasVideo = true }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard let firstPTS, writer.status == .writing, audio.isReadyForMoreMediaData,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), firstPTS) >= 0 else { return }
        if audio.append(sample) { hasAudio = true }
    }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard writer.status == .writing, hasVideo, hasAudio else {
            writer.cancelWriting(); try? FileManager.default.removeItem(at: url)
            completion(.failure(DualCameraFailure.recording)); return
        }
        video.markAsFinished(); audio.markAsFinished()
        writer.finishWriting { [writer, url] in
            if writer.status == .completed { completion(.success(url)) }
            else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(writer.error ?? DualCameraFailure.recording))
            }
        }
    }
}
