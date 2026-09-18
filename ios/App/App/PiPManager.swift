import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

@MainActor
final class PiPManager: NSObject, ObservableObject {
    static let shared = PiPManager()

    @Published private(set) var isSystemPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isSystemPiPActive = false
    @Published private(set) var isAppFloatingActive = false
    @Published private(set) var lastErrorMessage: String?

    private var pictureInPictureController: AVPictureInPictureController?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?

    private override init() {
        super.init()
    }

    func configure(with playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        guard isSystemPiPSupported else { return }
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            lastErrorMessage = "PiP 控制器创建失败"
            return
        }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPictureController = controller
    }

    func startSystemPiP() {
        guard isSystemPiPSupported else {
            lastErrorMessage = "当前设备不支持系统画中画"
            isAppFloatingActive = true
            return
        }
        guard let controller = pictureInPictureController else {
            lastErrorMessage = "PiP 尚未准备好，已切换为 App 内悬浮窗"
            isAppFloatingActive = true
            return
        }
        guard !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    func stopSystemPiP() {
        pictureInPictureController?.stopPictureInPicture()
    }

    func enterAppFloating() {
        isAppFloatingActive = true
    }

    func exitAppFloating() {
        isAppFloatingActive = false
    }

    func toggleFloating() {
        isAppFloatingActive.toggle()
    }

    func handleAppWillResignActive() {
        startSystemPiP()
    }

    func prepareSilentPlayerIfNeeded() -> AVPlayerLayer {
        if let playerLayer { return playerLayer }

        let item = AVPlayerItem(asset: Self.makeBlackVideoAsset())
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            item.seek(to: .zero, completionHandler: nil)
            player.play()
        }

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        configure(with: layer)
        player.play()
        return layer
    }

    private static func makeBlackVideoAsset() -> AVAsset {
        let composition = AVMutableComposition()
        _ = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 3600, preferredTimescale: 600)))
        return composition
    }
}

extension PiPManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isSystemPiPActive = true
            isAppFloatingActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            isSystemPiPActive = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            lastErrorMessage = error.localizedDescription
            isAppFloatingActive = true
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            isAppFloatingActive = false
            completionHandler(true)
        }
    }
}

struct PiPHostView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isHidden = true
        view.backgroundColor = .clear

        Task { @MainActor in
            let layer = PiPManager.shared.prepareSilentPlayerIfNeeded()
            layer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
            if layer.superlayer !== view.layer {
                view.layer.addSublayer(layer)
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        Task { @MainActor in
            PiPManager.shared.prepareSilentPlayerIfNeeded().frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        }
    }
}
