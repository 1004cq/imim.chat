import Foundation
import SwiftUI
import SDWebImageSwiftUI
import Lottie
import zlib

// Mirrors the authenticated CQIM `/api/stickers/packs?includeStickers=true` contract.
struct StickerPackResponse: Codable {
    let packs: [StickerPack]
}

struct StickerPack: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String?
    let description: String?
    let sourceType: String?
    let mediaType: String?
    let stickers: [StickerItem]
}

struct StickerItem: Codable, Identifiable, Hashable {
    let id: String
    let url: String?
    let emoji: String?
    let name: String?
    let keywords: [String]?
    let format: String?
    let width: Double?
    let height: Double?
    let file: String?
    let packId: String?
    let packName: String?
    let mediaType: String?
    let thumbUrl: String?

    var normalizedFormat: String {
        let explicit = format?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty { return explicit }
        guard let pathExtension = URL(string: url ?? "")?.pathExtension.lowercased(), !pathExtension.isEmpty else {
            return mediaType?.lowercased() ?? ""
        }
        return pathExtension
    }

    var isEmoji: Bool {
        mediaType?.lowercased() == "emoji" || normalizedFormat == "emoji" || (url ?? "").isEmpty
    }

    var isGIF: Bool {
        mediaType?.lowercased() == "gif" || normalizedFormat == "gif"
    }

    var isLottie: Bool {
        normalizedFormat == "json" || normalizedFormat == "tgs"
    }
}

enum CQIMMediaURL {
    static func resolve(_ value: String?) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        let normalized = value.hasPrefix("/") ? String(value.dropFirst()) : value
        return URL(string: "\(AppServer.origin)/\(normalized)")
    }
}

struct StickerRenderSource: Hashable, Identifiable {
    let id: String
    let url: URL?
    let thumbnailURL: URL?
    let emoji: String?
    let name: String?
    let format: String

    init(item: StickerItem, pack: StickerPack? = nil) {
        id = "\(pack?.id ?? item.packId ?? "library")-\(item.id)"
        url = CQIMMediaURL.resolve(item.url)
        thumbnailURL = CQIMMediaURL.resolve(item.thumbUrl)
        emoji = item.emoji
        name = item.packName ?? pack?.name ?? item.name
        format = item.normalizedFormat
    }

    init(message: Message) {
        id = message.messageId
        url = CQIMMediaURL.resolve(message.stickerURL ?? message.mediaURL)
        thumbnailURL = CQIMMediaURL.resolve(message.stickerThumbURL)
        emoji = message.stickerEmoji
        name = message.stickerName
        let explicit = message.stickerFormat?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        format = explicit?.isEmpty == false ? explicit! : url?.pathExtension.lowercased() ?? ""
    }

    var isLottie: Bool { format == "json" || format == "tgs" }
    var isTGS: Bool { format == "tgs" }
    var isAnimatedBitmap: Bool { format == "gif" || format == "webp" }
}

extension Message {
    var stickerRenderSource: StickerRenderSource? {
        let source = StickerRenderSource(message: self)
        guard source.url != nil else { return type == "sticker" || type == "gif" || type == "meme" ? source : nil }
        return type == "sticker" || type == "gif" || type == "meme" || source.isLottie || source.isAnimatedBitmap ? source : nil
    }
}

// MARK: Sticker playback policy (value-only, regression tested)
struct StickerPlaybackBudget {
    let capacity: Int
    private(set) var active: [UUID] = []
    private(set) var waiting: [UUID] = []

    mutating func request(_ id: UUID) -> Bool {
        if active.contains(id) { return true }
        if active.count < max(1, capacity) {
            waiting.removeAll { $0 == id }
            active.append(id)
            return true
        }
        if !waiting.contains(id) { waiting.append(id) }
        return false
    }

    mutating func release(_ id: UUID) {
        waiting.removeAll { $0 == id }
        active.removeAll { $0 == id }
        while active.count < max(1, capacity), !waiting.isEmpty {
            active.append(waiting.removeFirst())
        }
    }

    mutating func prioritize(_ id: UUID) {
        guard waiting.contains(id) else { return }
        waiting.removeAll { $0 == id }
        if active.count >= max(1, capacity), let displaced = active.popLast() {
            waiting.insert(displaced, at: 0)
        }
        active.append(id)
    }
}

enum StickerPlaybackEligibility {
    static func isVisible(frame: CGRect, viewport: CGSize) -> Bool {
        guard !frame.isInfinite, !frame.isNull,
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              frame.width > 0, frame.height > 0, viewport.width > 0, viewport.height > 0 else { return false }
        let intersection = frame.intersection(CGRect(origin: .zero, size: viewport))
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
    static func mayAnimate(visible: Bool, activeScene: Bool, reduceMotion: Bool, lowPower: Bool, failed: Bool) -> Bool {
        visible && activeScene && !reduceMotion && !lowPower && !failed
    }
}

struct StickerViewport {
    let name: String
    let size: CGSize
}

// MARK: Bounded sticker decoding (no disk cache or private-message persistence)
enum StickerAnimationDecode {
    static let maximumDownloadedBytes = 1_048_576
    static let maximumJSONBytes = 4_194_304

    static func jsonData(_ data: Data, isTGS: Bool) throws -> Data {
        guard !data.isEmpty, data.count <= maximumDownloadedBytes else { throw URLError(.dataLengthExceedsMaximum) }
        guard isTGS else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw URLError(.cannotDecodeContentData)
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var chunk = [UInt8](repeating: 0, count: 32_768)
            while true {
                try Task.checkCancellation()
                var produced = 0
                let status = chunk.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    produced = output.count - Int(stream.avail_out)
                    return status
                }
                guard produced <= maximumJSONBytes - result.count else { throw URLError(.dataLengthExceedsMaximum) }
                result.append(contentsOf: chunk.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, !result.isEmpty else { throw URLError(.cannotDecodeContentData) }
                    return result
                }
                guard status == Z_OK, produced > 0 || stream.avail_in > 0 else { throw URLError(.cannotDecodeContentData) }
            }
        }
    }
}

// Pass the freshly observed value into playback reconciliation. Geometry callbacks
// may outlive the environment snapshot from the render that installed them.
struct StickerPlaybackRequest: Equatable {
    let visible: Bool
    let activeScene: Bool
    let reduceMotion: Bool
    let lowPower: Bool
    let failed: Bool
    let animated: Bool
    let eligible: Bool
    let generation: Int
    let appearanceGeneration: Int

    init(visible: Bool, activeScene: Bool, reduceMotion: Bool, lowPower: Bool,
         failed: Bool, animated: Bool, generation: Int, appearanceGeneration: Int = 0) {
        self.visible = visible
        self.activeScene = activeScene
        self.reduceMotion = reduceMotion
        self.lowPower = lowPower
        self.failed = failed
        self.animated = animated
        eligible = animated && StickerPlaybackEligibility.mayAnimate(visible: visible,
            activeScene: activeScene, reduceMotion: reduceMotion, lowPower: lowPower, failed: failed)
        self.generation = generation
        self.appearanceGeneration = appearanceGeneration
    }
}

// MARK: UI-owned playback leases
@MainActor
final class StickerPlaybackCoordinator: ObservableObject {
    static let shared = StickerPlaybackCoordinator(maximumConcurrentAnimations: 6)
    static let picker = StickerPlaybackCoordinator(maximumConcurrentAnimations: 3)

    @Published private(set) var generation = 0
    private var budget: StickerPlaybackBudget

    private init(maximumConcurrentAnimations: Int) {
        budget = StickerPlaybackBudget(capacity: maximumConcurrentAnimations)
    }

    func acquire(_ id: UUID) -> Bool {
        let previous = budget.active
        let granted = budget.request(id)
        if previous != budget.active { generation &+= 1 }
        return granted
    }

    func release(_ id: UUID) {
        let previous = budget.active
        budget.release(id)
        if previous != budget.active { generation &+= 1 }
    }
    func prioritize(_ id: UUID) {
        let previous = budget.active
        budget.prioritize(id)
        if previous != budget.active { generation &+= 1 }
    }
}

private actor StickerAnimationDataCache {
    static let shared = StickerAnimationDataCache()

    private struct Key: Hashable { let url: URL; let isTGS: Bool }
    private struct Entry: Sendable { let animation: LottieAnimation; let cost: Int }
    private var values: [Key: Entry] = [:]
    private var inFlight: [Key: Task<Entry, Error>] = [:]
    private var accessOrder: [Key] = []
    private let capacity = 24
    private let byteBudget = 16_777_216
    private var byteCost = 0
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func animation(for url: URL, isTGS: Bool) async throws -> LottieAnimation {
        try Task.checkCancellation()
        let key = Key(url: url, isTGS: isTGS)
        if let cached = values[key] {
            touch(key)
            return cached.animation
        }
        if let task = inFlight[key] {
            let entry = try await task.value
            try Task.checkCancellation()
            return entry.animation
        }
        // Inherits this custom actor: streaming, inflate and JSON/model decode
        // do not run in the UIKit/MainActor coordinator. One task per URL/format.
        let task = Task { try await self.load(key) }
        inFlight[key] = task
        do {
            let entry = try await task.value
            inFlight[key] = nil
            values[key] = entry
            byteCost += entry.cost
            touch(key)
            while (accessOrder.count > capacity || byteCost > byteBudget), let expired = accessOrder.first {
                accessOrder.removeFirst()
                if let removed = values.removeValue(forKey: expired) { byteCost -= removed.cost }
            }
            try Task.checkCancellation()
            return entry.animation
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    private func load(_ key: Key) async throws -> Entry {
        var data = Data()
        if key.url.isFileURL {
            let size = try key.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= StickerAnimationDecode.maximumDownloadedBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data = try Data(contentsOf: key.url)
        } else {
            guard key.url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
            let request = URLRequest(url: key.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            guard response.expectedContentLength <= StickerAnimationDecode.maximumDownloadedBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.reserveCapacity(65_536)
            for try await byte in bytes {
                guard data.count < StickerAnimationDecode.maximumDownloadedBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
        }
        try Task.checkCancellation()
        let json = try StickerAnimationDecode.jsonData(data, isTGS: key.isTGS)
        let animation = try LottieAnimation.from(data: json)
        guard animation.bounds.width > 0, animation.bounds.width <= 2048, animation.bounds.height > 0, animation.bounds.height <= 2048,
              animation.framerate > 0, animation.framerate <= 120, animation.duration > 0, animation.duration <= 30 else {
            throw URLError(.cannotDecodeContentData)
        }
        return Entry(animation: animation, cost: json.count * 3)
    }

    private func touch(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

#if DEBUG || IMIM_STICKER_DIAGNOSTICS
@MainActor private enum StickerPlaybackTrace {
    static let enabled = ProcessInfo.processInfo.environment["IMIM_STICKER_TRACE"] == "1"
    static var remaining = 240
    static func record(_ event: String) {
        guard enabled, remaining > 0 else { return }; remaining -= 1
        try? FileHandle.standardOutput.write(contentsOf: Data(("[StickerPlayback] " + event + "\n").utf8))
    }
}
#endif

// UIKit application activity is authoritative here: a retained SwiftUI chat
// subtree can keep scenePhase inactive after navigation while its window is active.
// Keep motion, viewport and playback-budget gates independent of this lifecycle.
@MainActor
private final class StickerApplicationActivity: ObservableObject {
    static let shared = StickerApplicationActivity()
    @Published private(set) var isActive: Bool
    private let center: NotificationCenter
    private let readActive: @MainActor () -> Bool
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default,
         readActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.center = center
        self.readActive = readActive
        isActive = readActive()
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setActive(false) }
            })
        }
        tokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    deinit { for token in tokens { center.removeObserver(token) } }

    func refresh() { setActive(readActive()) }
    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
    }
}

@MainActor struct StickerAssetView: View {
    let source: StickerRenderSource
    let size: CGFloat
    let contentMode: SwiftUI.ContentMode
    let viewport: StickerViewport?
    let allowsReplay: Bool

    @ObservedObject private var applicationActivity = StickerApplicationActivity.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var playback: StickerPlaybackCoordinator
    // A view-instance lease, not a message/list identity. Repeated uses of one
    // pack item cannot release another instance's animation slot.
    @State private var playbackID = UUID()
    @State private var isMounted = false
    @State private var isVisible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var replayGeneration = 0
    @State private var isAnimating = false
    @State private var hasFailed = false
    @State private var playbackAllowed = false
    @State private var appearanceGeneration = 0

    init(source: StickerRenderSource, size: CGFloat = 118, contentMode: SwiftUI.ContentMode = .fit,
         viewport: StickerViewport? = nil, allowsReplay: Bool = true,
         coordinator: StickerPlaybackCoordinator? = nil) {
        self.source = source
        self.size = size
        self.contentMode = contentMode
        self.viewport = viewport
        self.allowsReplay = allowsReplay
        _playback = ObservedObject(wrappedValue: coordinator ?? .shared)
    }

    var body: some View {
        Group {
            if !isMounted || !isVisible {
                StickerPosterView(source: source, size: size)
            } else if hasFailed || source.url == nil {
                StickerUnavailableView(emoji: source.emoji, size: size)
            } else if source.format == "webm" {
                StickerPosterView(source: source, size: size)
                    .overlay(alignment: .bottom) {
                        Text(verbatim: ProxyCopy.text("暂不支持此视频贴纸", "Video sticker not supported yet"))
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
            } else if source.isLottie, let url = source.url {
                LottieStickerView(url: url, size: size, isTGS: source.isTGS, isAnimating: isAnimating, replayGeneration: replayGeneration) {
                    hasFailed = true
                }
            } else if let url = source.url {
                AnimatedImage(url: url, isAnimating: $isAnimating) {
                    StickerUnavailableView(emoji: source.emoji, size: size)
                }
                .onFailure { _ in
                    DispatchQueue.main.async { hasFailed = true }
                }
                .resizable()
                .onViewUpdate { view, _ in
                    view.contentMode = .scaleAspectFit
                    view.clipsToBounds = true
                }
                .pausable(true)
                .purgeable(true)
                .aspectRatio(contentMode: contentMode)
                .frame(width: size, height: size)
                .id(replayGeneration)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onGeometryChange(for: Bool.self) { geometry in
            let frame = geometry.frame(in: viewport.map { .named($0.name) } ?? .global)
            return StickerPlaybackEligibility.isVisible(frame: frame, viewport: viewport?.size ?? UIScreen.main.bounds.size)
        } action: { visible in
            isVisible = visible
        }
        .onAppear {
            applicationActivity.refresh()
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            isMounted = true
            // A retained row can disappear and reappear without an observed
            // false eligibility render. Reacquire even if eligibility is equal.
            appearanceGeneration &+= 1
        }
        .onDisappear {
            isMounted = false
            playbackAllowed = false
            isAnimating = false
            playback.release(playbackID)
        }
        .onChange(of: playbackRequest, initial: true) { _, request in
            #if DEBUG || IMIM_STICKER_DIAGNOSTICS
            StickerPlaybackTrace.record("request visible=\(request.visible) active=\(request.activeScene) reduce=\(request.reduceMotion) power=\(request.lowPower) failed=\(request.failed) animated=\(request.animated) eligible=\(request.eligible) mountedNow=\(isMounted) visibleNow=\(isVisible) appearance=\(request.appearanceGeneration)")
            #endif
            updatePlayback(eligible: request.eligible)
        }
        .onChange(of: source) { _, _ in
            hasFailed = false
            replayGeneration = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .modifier(StickerReplayTap(enabled: allowsReplay, replay: replay))
        .accessibilityLabel(source.emoji ?? ProxyCopy.text("贴纸", "Sticker"))
    }

    private var playbackRequest: StickerPlaybackRequest {
        StickerPlaybackRequest(
            visible: isMounted && isVisible, activeScene: applicationActivity.isActive,
            reduceMotion: reduceMotion, lowPower: lowPower, failed: hasFailed,
            animated: source.isLottie || source.isAnimatedBitmap, generation: playback.generation,
            appearanceGeneration: appearanceGeneration)
    }

    private func updatePlayback(eligible requested: Bool) {
        // A queued observation must not reacquire after onDisappear released.
        let eligible = requested && isMounted && isVisible
        #if DEBUG || IMIM_STICKER_DIAGNOSTICS
        let wasAllowed = playbackAllowed
        let wasAnimating = isAnimating
        #endif
        playbackAllowed = eligible
        if eligible {
            isAnimating = playback.acquire(playbackID)
        } else {
            isAnimating = false
            playback.release(playbackID)
        }
        #if DEBUG || IMIM_STICKER_DIAGNOSTICS
        if isMounted && isVisible && (wasAllowed != eligible || wasAnimating != isAnimating) {
            StickerPlaybackTrace.record("eligible=\(eligible) playing=\(isAnimating) lottie=\(source.isLottie) bitmap=\(source.isAnimatedBitmap) appearance=\(appearanceGeneration)")
        }
        #endif
    }

    private func replay() {
        guard isMounted, isVisible else { return }
        hasFailed = false
        // A failed asset retries through the fresh request once hasFailed clears.
        guard playbackAllowed else { return }
        playback.prioritize(playbackID)
        isAnimating = playback.acquire(playbackID)
        replayGeneration &+= 1
    }
}

private struct StickerReplayTap: ViewModifier {
    let enabled: Bool
    let replay: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture(perform: replay)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: Text(verbatim: ProxyCopy.text("重播贴纸", "Replay sticker")), replay)
        } else { content }
    }
}

private struct StickerPosterView: View {
    let source: StickerRenderSource
    let size: CGFloat
    var body: some View {
        Group {
            if let thumbnail = source.thumbnailURL {
                WebImage(url: thumbnail).resizable().scaledToFit()
            } else {
                Text(source.emoji?.isEmpty == false ? source.emoji! : "✨")
                    .font(.system(size: max(24, size * 0.36)))
            }
        }.frame(width: size, height: size)
    }
}

private struct StickerUnavailableView: View {
    let emoji: String?
    let size: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Text(emoji?.isEmpty == false ? emoji! : "?")
                .font(.system(size: max(24, size * 0.36)))
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("贴纸加载失败")
    }
}

@MainActor
private final class StickerAnimationContainer: UIView {
    let animationView = LottieAnimationView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        animationView.contentMode = .scaleAspectFit
        animationView.backgroundColor = .clear
        animationView.isOpaque = false
        addSubview(animationView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        animationView.frame = bounds
        animationView.setNeedsLayout()
        animationView.layoutIfNeeded()
    }
}

private struct LottieStickerView: UIViewRepresentable {
    let url: URL
    let size: CGFloat
    let isTGS: Bool
    let isAnimating: Bool
    let replayGeneration: Int
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> StickerAnimationContainer {
        let container = StickerAnimationContainer(frame: .zero)
        let view = container.animationView
        view.contentMode = .scaleAspectFit
        view.loopMode = .loop
        // UIKit may detach and reattach a retained player without a SwiftUI
        // value change. Restore its in-flight loop when the window returns.
        // Explicit lease revocation/dismantling still calls pause().
        view.backgroundBehavior = .pauseAndRestore
        view.backgroundColor = .clear
        view.isOpaque = false
        view.respectAnimationFrameRate = true
        view.shouldRasterizeWhenIdle = true
        context.coordinator.setPlaying(isAnimating, for: view)
        context.coordinator.replay(replayGeneration, in: view)
        context.coordinator.load(url: url, isTGS: isTGS, into: view, onFailure: onFailure)
        return container
    }

    func updateUIView(_ container: StickerAnimationContainer, context: Context) {
        let view = container.animationView
        if context.coordinator.loadedURL != url || context.coordinator.loadedIsTGS != isTGS {
            context.coordinator.load(url: url, isTGS: isTGS, into: view, onFailure: onFailure)
        }
        context.coordinator.setPlaying(isAnimating, for: view)
        context.coordinator.replay(replayGeneration, in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: StickerAnimationContainer, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }

    static func dismantleUIView(_ uiView: StickerAnimationContainer, coordinator: Coordinator) {
        coordinator.task?.cancel()
        coordinator.task = nil
        uiView.animationView.pause()
        #if DEBUG || IMIM_STICKER_DIAGNOSTICS
        coordinator.stopProgressProbe()
        #endif
    }

    @MainActor final class Coordinator {
        var loadedURL: URL?
        var loadedIsTGS: Bool?
        var task: Task<Void, Never>?
        private var shouldPlay = false
        private var replayGeneration = 0
        #if DEBUG || IMIM_STICKER_DIAGNOSTICS
        private var progressProbe: Task<Void, Never>?
        deinit { progressProbe?.cancel() }
        func stopProgressProbe() { progressProbe?.cancel(); progressProbe = nil }
        private func startProgressProbe(in view: LottieAnimationView) {
            guard StickerPlaybackTrace.enabled else { return }
            stopProgressProbe()
            progressProbe = Task { @MainActor [weak view] in
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled, let view else { return }
                    StickerPlaybackTrace.record("progress=\(view.realtimeAnimationProgress) running=\(view.isAnimationPlaying)")
                }
            }
        }
        #endif

        func replay(_ generation: Int, in view: LottieAnimationView) {
            guard replayGeneration != generation else { return }
            replayGeneration = generation
            view.currentProgress = 0
            if shouldPlay, view.animation != nil { view.play() }
        }

        func setPlaying(_ shouldPlay: Bool, for view: LottieAnimationView) {
            self.shouldPlay = shouldPlay
            if shouldPlay {
                if view.animation != nil, !view.isAnimationPlaying {
                    view.play()
                    #if DEBUG || IMIM_STICKER_DIAGNOSTICS
                    startProgressProbe(in: view)
                    #endif
                }
            } else {
                view.pause()
                #if DEBUG || IMIM_STICKER_DIAGNOSTICS
                stopProgressProbe()
                #endif
            }
        }

        func load(url: URL, isTGS: Bool, into view: LottieAnimationView, onFailure: @escaping () -> Void) {
            task?.cancel()
            loadedURL = url
            loadedIsTGS = isTGS
            view.pause()
            view.animation = nil
            task = Task { [weak self, weak view] in
                do {
                    let animation = try await StickerAnimationDataCache.shared.animation(for: url, isTGS: isTGS)
                    try Task.checkCancellation()
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, let view, self.loadedURL == url, self.loadedIsTGS == isTGS else { return }
                        view.animation = animation
                        view.loopMode = .loop
                        if self.shouldPlay { view.play() }
                        #if DEBUG || IMIM_STICKER_DIAGNOSTICS
                        StickerPlaybackTrace.record("loaded duration=\(animation.duration) wanted=\(self.shouldPlay) running=\(view.isAnimationPlaying) window=\(view.window != nil) width=\(view.bounds.width)")
                        self.startProgressProbe(in: view)
                        #endif
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.loadedURL == url, self.loadedIsTGS == isTGS else { return }
                        onFailure()
                    }
                }
            }
        }
    }
}

// Transient pack metadata only; no messages, keys or credentials are cached.
struct StickerPanelCatalogCache {
    private var ownerID: String?
    private var values: [StickerPack] = []
    private var loadedAt: Date?

    func packs(for owner: String) -> [StickerPack] {
        ownerID == owner ? values : []
    }
    func isFresh(for owner: String, now: Date = Date()) -> Bool {
        guard ownerID == owner, let loadedAt else { return false }
        let age = now.timeIntervalSince(loadedAt)
        return age >= 0 && age < 60
    }
    mutating func store(_ packs: [StickerPack], owner: String, now: Date = Date()) {
        ownerID = owner
        values = packs
        loadedAt = now
    }
}

@MainActor private enum StickerPanelMemory {
    static var catalog = StickerPanelCatalogCache()
}

struct ChatControlPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.96 : 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@MainActor struct StickerMediaPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case emoji = "表情"
        case sticker = "贴纸"
        case gif = "GIF"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .emoji: return "face.smiling"
            case .sticker: return "sparkles"
            case .gif: return "gif"
            }
        }
    }

    let ownerID: String
    let onSelectEmoji: (String) -> Void
    let onSelectSticker: (StickerItem, StickerPack?) -> Void
    let onDismiss: () -> Void

    @State private var tab: Tab = .emoji
    @State private var packs: [StickerPack] = []
    @State private var selectedPackID: String?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var loadID = UUID()
    @State private var selectionFeedback = 0
    @State private var reloadGeneration = 0
    @State private var importSheet: ImportSheet?
    private struct ImportSheet: Identifiable { let id = "sticker-import" }

    init(ownerID: String, onSelectEmoji: @escaping (String) -> Void,
         onSelectSticker: @escaping (StickerItem, StickerPack?) -> Void,
         onDismiss: @escaping () -> Void) {
        self.ownerID = ownerID
        self.onSelectEmoji = onSelectEmoji
        self.onSelectSticker = onSelectSticker
        self.onDismiss = onDismiss
        _packs = State(initialValue: StickerPanelMemory.catalog.packs(for: ownerID))
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    private let emoji = ["😀", "😃", "😄", "😁", "🥹", "😂", "🙂", "😉", "😊", "😍", "😘", "😎", "🤔", "😭", "😤", "🥳", "👍", "👏", "🙌", "🙏", "👋", "❤️", "🔥", "🎉", "✨", "💯", "✅", "❌", "💬", "🎁"]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Picker("媒体类别", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Label(LocalizedStringKey(tab.rawValue), systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Button { importSheet = ImportSheet() } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(ChatControlPressStyle())
                .accessibilityLabel(ProxyCopy.text("添加贴纸包", "Add sticker pack"))

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(ChatControlPressStyle())
                .accessibilityLabel("关闭表情贴纸")
            }

            Group {
                if tab == .emoji {
                    ScrollView { emojiGrid }
                        .scrollIndicators(.hidden)
                } else {
                    VStack(spacing: 10) { packContent }
                }
            }
            .frame(height: 260, alignment: .top)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .sensoryFeedback(.selection, trigger: tab)
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .task(id: "\(ownerID)|\(reloadGeneration)") { await loadPacksIfNeeded(force: reloadGeneration > 0) }
        .sheet(item: $importSheet, onDismiss: { reloadGeneration &+= 1 }) { _ in
            NavigationStack { StickerPackImportView() }
        }
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 6) {
            ForEach(emoji, id: \.self) { value in
                Button {
                    onSelectEmoji(value)
                } label: {
                    Text(value)
                        .font(.system(size: 25))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(ChatControlPressStyle())
            }
        }
    }

    @ViewBuilder
    private var packContent: some View {
        let filteredPacks = packsForSelectedTab
        if isLoading && packs.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 144)
        } else if let loadError, packs.isEmpty {
            VStack(spacing: 8) {
                AppLocalizedText(loadError).font(.footnote).foregroundStyle(.secondary)
                Button("重新加载") { reloadGeneration &+= 1 }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 144)
        } else if filteredPacks.isEmpty {
            ContentUnavailableView(tab == .gif ? AppLocalization.text("暂无 GIF") : AppLocalization.text("暂无贴纸"), systemImage: "sparkles")
                .frame(maxWidth: .infinity, minHeight: 144)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filteredPacks) { pack in
                        Button {
                            if selectedPackID != pack.id { selectionFeedback &+= 1 }
                            selectedPackID = pack.id
                        } label: {
                            Text(pack.icon ?? pack.name.prefix(1).description)
                                .font(.system(size: 20))
                                .frame(width: 44, height: 44)
                                .background(selectedPackID == pack.id ? DoveTheme.green.opacity(0.18) : Color.clear, in: Circle())
                        }
                        .buttonStyle(ChatControlPressStyle())
                        .accessibilityLabel(pack.name)
                    }
                }
            }

            if let pack = activePack(in: filteredPacks) {
                GeometryReader { viewport in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(items(for: pack)) { item in
                                Button {
                                    onSelectSticker(item, pack)
                                } label: {
                                    StickerAssetView(source: StickerRenderSource(item: item, pack: pack), size: 58,
                                        viewport: StickerViewport(name: "stickerPicker", size: viewport.size),
                                        allowsReplay: false, coordinator: .picker)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(ChatControlPressStyle())
                                .accessibilityLabel(item.name ?? item.emoji ?? AppLocalization.text("贴纸"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .coordinateSpace(name: "stickerPicker")
                }
                .frame(height: 205)
            }
        }
    }

    private var packsForSelectedTab: [StickerPack] {
        packs.filter { pack in
            let matches = pack.stickers.contains { item in
                tab == .gif ? item.isGIF : !item.isGIF && !item.isEmoji
            }
            return matches
        }
    }

    private func activePack(in packs: [StickerPack]) -> StickerPack? {
        if let selectedPackID, let selected = packs.first(where: { $0.id == selectedPackID }) {
            return selected
        }
        return packs.first
    }

    private func items(for pack: StickerPack) -> [StickerItem] {
        pack.stickers.filter { tab == .gif ? $0.isGIF : !$0.isGIF && !$0.isEmoji }
    }

    private func loadPacksIfNeeded(force: Bool) async {
        packs = StickerPanelMemory.catalog.packs(for: ownerID)
        // Refresh off the critical display path; keep warm tiles mounted.
        if !force && StickerPanelMemory.catalog.isFresh(for: ownerID) { return }
        await reloadPacks()
    }

    private func reloadPacks() async {
        let requestID = UUID()
        loadID = requestID
        isLoading = packs.isEmpty
        loadError = nil
        let token = AuthTokenStore.shared.token
        defer { if loadID == requestID { isLoading = false } }
        do {
            let refreshed = try await APIClient.shared.fetchStickerPacks()
            try Task.checkCancellation()
            guard loadID == requestID, token == AuthTokenStore.shared.token else { return }
            packs = refreshed
            StickerPanelMemory.catalog.store(refreshed, owner: ownerID)
            if !packsForSelectedTab.contains(where: { $0.id == selectedPackID }) {
                selectedPackID = packsForSelectedTab.first?.id
            }
        } catch {
            if loadID == requestID, !Task.isCancelled, !(error is CancellationError) {
                loadError = "贴纸加载失败，请检查网络后重试"
            }
        }
    }
}

// MARK: Telegram pack import (server-side existing API, no Bot key in client)
enum StickerPackLink {
    static func shortName(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048 else { throw URLError(.badURL) }
        let name: String
        if value.contains("://") {
            guard let c = URLComponents(string: value), c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else {
                throw URLError(.badURL)
            }
            if c.scheme?.lowercased() == "https", ["t.me", "telegram.me", "telegram.dog"].contains(c.host?.lowercased() ?? "") {
                let parts = c.path.split(separator: "/")
                guard parts.count == 2, parts[0] == "addstickers", c.query == nil else { throw URLError(.badURL) }
                name = String(parts[1])
            } else if c.scheme?.lowercased() == "tg", c.host == "addstickers", c.path.isEmpty,
                      let items = c.queryItems, items.count == 1, items[0].name == "set", let set = items[0].value {
                name = set
            } else { throw URLError(.badURL) }
        } else { name = value }
        guard (1...64).contains(name.utf8.count), name.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0.value == 95
        }) else { throw URLError(.badURL) }
        return name
    }
}

struct StickerInstallResponse: Codable {
    struct Pack: Codable { let id: String }
    let success: Bool
    let pack: Pack
}

private struct StickerPackImportView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppLanguage.preferenceKey) private var languagePreference = AppLanguage.system.rawValue
    @State private var input = ""
    @State private var permitted = false
    @State private var isInstalling = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField(ProxyCopy.text("贴纸包链接或短名", "Sticker pack link or short name"), text: $input)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            } footer: {
                Text(verbatim: "https://t.me/addstickers/PackName")
            }
            Section {
                Toggle(ProxyCopy.text("我有权在此 App 中使用这些贴纸", "I have permission to use these stickers in this app"), isOn: $permitted)
            } footer: {
                Text(verbatim: ProxyCopy.text("贴纸由服务器同步到现有贴纸库。服务器需配置 Telegram 导入能力，App 不保存 Bot 密钥。",
                    "The server imports assets into the existing sticker library. Telegram import must be configured on the server; no Bot key is stored in the app."))
            }
            if let error { Text(verbatim: error).foregroundStyle(.red).font(.footnote) }
            Section {
                Button {
                    Task { await install() }
                } label: {
                    HStack {
                        if isInstalling { ProgressView() }
                        Text(verbatim: ProxyCopy.text(isInstalling ? "正在添加…" : "添加贴纸包", isInstalling ? "Adding…" : "Add sticker pack"))
                    }
                }.disabled(!permitted || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isInstalling)
            }
        }
        .navigationTitle(ProxyCopy.text("添加贴纸包", "Add sticker pack"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(ProxyCopy.text("关闭", "Close")) { dismiss() }.disabled(isInstalling)
        } }
        .interactiveDismissDisabled(isInstalling)
        .environment(\.locale, (AppLanguage(rawValue: languagePreference) ?? .system).locale)
    }
    private func install() async {
        guard permitted, !isInstalling else { return }
        let name: String
        do { name = try StickerPackLink.shortName(input) }
        catch { self.error = ProxyCopy.text("请输入有效的 Telegram 贴纸包链接或短名。", "Enter a valid Telegram sticker pack link or short name."); return }
        isInstalling = true
        error = nil
        defer { isInstalling = false }
        do {
            _ = try await APIClient.shared.installStickerPack(shortName: name)
            dismiss()
        } catch {
            self.error = ProxyCopy.text("无法添加贴纸包，请核对链接和服务器的 Telegram 导入配置。",
                "Unable to add this pack. Check the link and the server’s Telegram import configuration.")
        }
    }
}
