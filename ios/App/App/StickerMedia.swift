import Foundation
import SwiftUI
import SDWebImageSwiftUI
import Lottie
import Gzip

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
        return URL(string: "https://wed.imim.chat/\(normalized)")
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

@MainActor
final class StickerPlaybackCoordinator: ObservableObject {
    static let shared = StickerPlaybackCoordinator(maximumConcurrentAnimations: 3)

    @Published private(set) var generation = 0
    private let maximumConcurrentAnimations: Int
    private var activeIDs: [String] = []

    private init(maximumConcurrentAnimations: Int) {
        self.maximumConcurrentAnimations = maximumConcurrentAnimations
    }

    func acquire(_ id: String) -> Bool {
        if activeIDs.contains(id) { return true }
        guard activeIDs.count < maximumConcurrentAnimations else { return false }
        activeIDs.append(id)
        generation &+= 1
        return true
    }

    func release(_ id: String) {
        guard let index = activeIDs.firstIndex(of: id) else { return }
        activeIDs.remove(at: index)
        generation &+= 1
    }
}

private actor StickerAnimationDataCache {
    static let shared = StickerAnimationDataCache()

    private var values: [URL: Data] = [:]
    private var accessOrder: [URL] = []
    private let capacity = 24

    func data(for url: URL) async throws -> Data {
        if let cached = values[url] {
            touch(url)
            return cached
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        values[url] = data
        touch(url)
        while accessOrder.count > capacity, let expired = accessOrder.first {
            accessOrder.removeFirst()
            values.removeValue(forKey: expired)
        }
        return data
    }

    private func touch(_ url: URL) {
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
    }
}

struct StickerAssetView: View {
    let source: StickerRenderSource
    let size: CGFloat
    let contentMode: ContentMode

    @ObservedObject private var playback = StickerPlaybackCoordinator.shared
    @State private var isVisible = false
    @State private var isAnimating = false
    @State private var hasFailed = false

    init(source: StickerRenderSource, size: CGFloat = 118, contentMode: ContentMode = .fit) {
        self.source = source
        self.size = size
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if hasFailed || source.url == nil {
                StickerUnavailableView(emoji: source.emoji, size: size)
            } else if source.isLottie, let url = source.url {
                LottieStickerView(url: url, isTGS: source.isTGS, isAnimating: isAnimating) {
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
                .aspectRatio(contentMode: contentMode)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear {
            isVisible = true
            updatePlayback()
        }
        .onDisappear {
            isVisible = false
            isAnimating = false
            playback.release(source.id)
        }
        .onChange(of: playback.generation) { _, _ in
            updatePlayback()
        }
    }

    private func updatePlayback() {
        guard isVisible else { return }
        if source.isLottie || source.isAnimatedBitmap {
            isAnimating = playback.acquire(source.id)
        } else {
            isAnimating = false
        }
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

private struct LottieStickerView: UIViewRepresentable {
    let url: URL
    let isTGS: Bool
    let isAnimating: Bool
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.contentMode = .scaleAspectFit
        view.loopMode = .loop
        view.backgroundBehavior = .pause
        context.coordinator.setPlaying(isAnimating, for: view)
        context.coordinator.load(url: url, isTGS: isTGS, into: view, onFailure: onFailure)
        return view
    }

    func updateUIView(_ view: LottieAnimationView, context: Context) {
        if context.coordinator.loadedURL != url {
            context.coordinator.load(url: url, isTGS: isTGS, into: view, onFailure: onFailure)
        }
        context.coordinator.setPlaying(isAnimating, for: view)
    }

    static func dismantleUIView(_ uiView: LottieAnimationView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        uiView.pause()
    }

    final class Coordinator {
        var loadedURL: URL?
        var task: Task<Void, Never>?
        private var shouldPlay = false

        func setPlaying(_ shouldPlay: Bool, for view: LottieAnimationView) {
            self.shouldPlay = shouldPlay
            if shouldPlay {
                if view.animation != nil, !view.isAnimationPlaying { view.play() }
            } else {
                view.pause()
            }
        }

        func load(url: URL, isTGS: Bool, into view: LottieAnimationView, onFailure: @escaping () -> Void) {
            task?.cancel()
            loadedURL = url
            task = Task {
                do {
                    let remoteData = try await StickerAnimationDataCache.shared.data(for: url)
                    try Task.checkCancellation()
                    let animationData = isTGS ? try remoteData.gunzipped() : remoteData
                    let animation = try LottieAnimation.from(data: animationData)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self.loadedURL == url else { return }
                        view.animation = animation
                        view.loopMode = .loop
                        if self.shouldPlay { view.play() }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self.loadedURL == url else { return }
                        onFailure()
                    }
                }
            }
        }
    }
}

struct StickerMediaPanel: View {
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

    let onSelectEmoji: (String) -> Void
    let onSelectSticker: (StickerItem, StickerPack?) -> Void

    @State private var tab: Tab = .emoji
    @State private var packs: [StickerPack] = []
    @State private var selectedPackID: String?
    @State private var loadError: String?
    @State private var isLoading = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)
    private let emoji = ["😀", "😃", "😄", "😁", "🥹", "😂", "🙂", "😉", "😊", "😍", "😘", "😎", "🤔", "😭", "😤", "🥳", "👍", "👏", "🙌", "🙏", "👋", "❤️", "🔥", "🎉", "✨", "💯", "✅", "❌", "💬", "🎁"]

    var body: some View {
        VStack(spacing: 10) {
            Picker("媒体类别", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if tab == .emoji {
                emojiGrid
            } else {
                packContent
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .task { await loadPacksIfNeeded() }
    }

    private var emojiGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 6) {
            ForEach(emoji, id: \.self) { value in
                Button {
                    onSelectEmoji(value)
                } label: {
                    Text(value)
                        .font(.system(size: 25))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var packContent: some View {
        let filteredPacks = packsForSelectedTab
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, minHeight: 144)
        } else if let loadError {
            VStack(spacing: 8) {
                Text(loadError).font(.footnote).foregroundStyle(.secondary)
                Button("重新加载") { Task { await reloadPacks() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 144)
        } else if filteredPacks.isEmpty {
            ContentUnavailableView(tab == .gif ? "暂无 GIF" : "暂无贴纸", systemImage: "sparkles")
                .frame(maxWidth: .infinity, minHeight: 144)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filteredPacks) { pack in
                        Button {
                            selectedPackID = pack.id
                        } label: {
                            Text(pack.icon ?? pack.name.prefix(1).description)
                                .font(.system(size: 20))
                                .frame(width: 36, height: 36)
                                .background(selectedPackID == pack.id ? DoveTheme.green.opacity(0.18) : Color.clear, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(pack.name)
                    }
                }
            }

            if let pack = activePack(in: filteredPacks) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(items(for: pack)) { item in
                            Button {
                                onSelectSticker(item, pack)
                            } label: {
                                StickerAssetView(source: StickerRenderSource(item: item, pack: pack), size: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name ?? item.emoji ?? "贴纸")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 205)
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

    private func loadPacksIfNeeded() async {
        guard packs.isEmpty, !isLoading else { return }
        await reloadPacks()
    }

    private func reloadPacks() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            packs = try await APIClient.shared.fetchStickerPacks()
            selectedPackID = packsForSelectedTab.first?.id
        } catch {
            loadError = "贴纸加载失败，请检查网络后重试"
        }
    }
}
