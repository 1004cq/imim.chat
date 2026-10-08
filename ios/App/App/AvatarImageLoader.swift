import CryptoKit
import Kingfisher
import SwiftUI
import UIKit

/// UI-owned coordination for SwiftUI and UIKit. Rows do not own downloads:
/// disappearing/recycling one row must not cancel another row's request.
@MainActor
final class AvatarImageLoader {
    static let shared = AvatarImageLoader()

    struct Source: Hashable, Sendable {
        var userId: String?
        var urlString: String?
    }

    private final class Binding: NSObject {
        let key: String
        let url: URL?
        init(key: String, url: URL?) { self.key = key; self.url = url }
    }

    private struct Request {
        let id: UUID
        var latestURL: URL
        var isVisible: Bool
        var isActive = false
    }

    private let cache: ImageCache
    private let downloader: ImageDownloader
    private let defaults: UserDefaults
    private let bindings = NSMapTable<UIImageView, Binding>.weakToStrongObjects()
    private var requests: [String: Request] = [:]
    private var latestSources: [String: URL] = [:]
    private var authoritativeSources: Set<String> = []
    private var failedRequests: [String: (url: URL, date: Date)] = [:]
    private var cacheReads: [String: UUID] = [:]
    private var pendingKeys: [String] = []
    private let maximumConcurrentDownloads: Int

    // Generated fallback images only; real peer images stay in Kingfisher.
    // MainActor owns this bounded, purgeable cache just like UIKit rendering.
    private static let placeholders: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private static let hexadecimalDigits = Array("0123456789abcdef".utf8)

    init(
        cache: ImageCache = ImageCache(name: "IMIMPeerAvatars"),
        downloader: ImageDownloader = .default,
        defaults: UserDefaults = .standard,
        maximumConcurrentDownloads: Int = 4
    ) {
        self.cache = cache
        self.downloader = downloader
        self.defaults = defaults
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
        cache.diskStorage.config.expiration = .never
        cache.diskStorage.config.sizeLimit = 64 * 1024 * 1024
        cache.memoryStorage.config.totalCostLimit = 24 * 1024 * 1024
    }

    static func cacheKey(userId: String?, urlString: String?) -> String? {
        if let id = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        // Query signatures/expiry must not create another cache identity.
        return remoteURL(from: urlString)?.path
    }

    static func remoteURL(from value: String?) -> URL? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        let resolved = trimmed.hasPrefix("/") ? "\(AppServer.origin)\(trimmed)" : trimmed
        guard let url = URL(string: resolved),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func loadAvatar(
        urlString: String?, userId: String? = nil, name: String? = nil,
        isGroup: Bool = false, allowsSourceUpdates: Bool = true,
        placeholder: UIImage? = nil, into imageView: UIImageView
    ) {
        shared.load(urlString: urlString, userId: userId, name: name, isGroup: isGroup,
                    allowsSourceUpdates: allowsSourceUpdates, placeholder: placeholder, into: imageView)
    }

    /// Queue off-screen avatars without creating image views or waiting for
    /// network IO. Kingfisher reads/decodes disk entries on its IO queue.
    func prefetch(_ sources: [Source], allowsSourceUpdates: Bool = true) {
        for source in sources {
            guard let url = Self.remoteURL(from: source.urlString),
                  let key = Self.cacheKey(userId: source.userId, urlString: source.urlString) else { continue }
            // A locally uploaded own-avatar path must never become an HTTP URL.
            if let path = source.urlString, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) { continue }
            let desiredURL = allowsSourceUpdates ? url : (latestSources[key] ?? url)
            latestSources[key] = desiredURL
            if allowsSourceUpdates { authoritativeSources.insert(key) }
            if requests[key] != nil {
                enqueue(desiredURL, forKey: key, isVisible: false)
                continue
            }
            if cache.retrieveImageInMemoryCache(forKey: key) != nil {
                prepareDownload(desiredURL, forKey: key, hasImage: true, isVisible: false)
                continue
            }
            // Merge cache prewarming too, not just network requests.
            guard cacheReads[key] == nil else { continue }
            let readID = UUID()
            let revisionBeforeRead = defaults.string(forKey: revisionKey(key))
            cacheReads[key] = readID
            cache.retrieveImageInDiskCache(forKey: key, callbackQueue: .mainCurrentOrAsync) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.cacheReads[key] == readID,
                          let latestURL = self.latestSources[key] else { return }
                    self.cacheReads.removeValue(forKey: key)
                    let diskImage = try? result.get()
                    // A completed newer download takes precedence over an old
                    // disk read that was started before that download.
                    if let diskImage,
                       self.cache.retrieveImageInMemoryCache(forKey: key) == nil,
                       self.defaults.string(forKey: self.revisionKey(key)) == revisionBeforeRead {
                        self.cache.store(diskImage, forKey: key, toDisk: false)
                    }
                    self.prepareDownload(latestURL, forKey: key,
                        hasImage: self.cache.retrieveImageInMemoryCache(forKey: key) != nil,
                        isVisible: false)
                }
            }
        }
    }

    func load(
        urlString: String?, userId: String? = nil, name: String? = nil,
        isGroup: Bool = false, allowsSourceUpdates: Bool = true,
        placeholder: UIImage? = nil, into imageView: UIImageView
    ) {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.kf.indicatorType = .none
        let previousBinding = bindings.object(forKey: imageView)
        bindings.removeObject(forKey: imageView)

        // AvatarStore stays exclusively for locally uploaded user files.
        if let localImage = AvatarStore.image(from: urlString) {
            imageView.image = localImage
            return
        }

        if let value = urlString, value.hasPrefix("asset://"),
           let asset = UIImage(named: String(value.dropFirst("asset://".count))) {
            imageView.image = asset
            return
        }

        guard let key = Self.cacheKey(userId: userId, urlString: urlString) else {
            imageView.image = placeholder ?? Self.placeholderImage(size: imageView.bounds.size, name: name, isGroup: isGroup)
            return
        }
        let remoteURL = allowsSourceUpdates
            ? Self.remoteURL(from: urlString)
            : (latestSources[key] ?? Self.remoteURL(from: urlString))
        bindings.setObject(Binding(key: key, url: remoteURL), forKey: imageView)

        // Read the small avatar for the first frame, including after process
        // restart. Network work never blocks this synchronous cache-only path.
        var image = cachedImage(forKey: key)
        if image == nil, let url = Self.remoteURL(from: urlString),
           let legacy = cachedImage(forKey: url.absoluteString, in: .default) {
            image = legacy
            cache.store(legacy, forKey: key)
        }
        imageView.image = image ?? placeholder ?? Self.placeholderImage(size: imageView.bounds.size, name: name, isGroup: isGroup)

        guard let url = remoteURL else { return }
        // An unchanged, already bound row may still carry the old profile URL.
        // Its redraw must not undo a newer URL supplied by another surface.
        if previousBinding?.key == key, previousBinding?.url == url,
           let latest = latestSources[key], latest != url { return }
        latestSources[key] = url
        if allowsSourceUpdates { authoritativeSources.insert(key) }
        prepareDownload(url, forKey: key, hasImage: image != nil, isVisible: true)
    }

    private func prepareDownload(_ url: URL, forKey key: String, hasImage: Bool, isVisible: Bool) {
        if requests[key] != nil {
            enqueue(url, forKey: key, isVisible: isVisible)
            return
        }
        // Historical feed snapshots are not current profile data. After a
        // restart, keep a cached avatar even when the snapshot's URL differs.
        if hasImage && !authoritativeSources.contains(key) { return }
        if hasImage, defaults.string(forKey: revisionKey(key)) == revision(url) { return }
        if let failed = failedRequests[key], failed.url == url,
           Date().timeIntervalSince(failed.date) < 15 { return }
        enqueue(url, forKey: key, isVisible: isVisible)
    }

    func unbind(_ imageView: UIImageView) { bindings.removeObject(forKey: imageView) }

    /// Notifications share the stable peer cache with conversation rows. Disk
    /// IO remains on Kingfisher's queue; this does not change avatar revisions.
    func cachedNotificationImage(userId: String?, urlString: String?) async -> UIImage? {
        if let value = urlString, value.hasPrefix("asset://") {
            return UIImage(named: String(value.dropFirst("asset://".count)))
        }
        guard let key = Self.cacheKey(userId: userId, urlString: urlString) else { return nil }
        if let image = cache.retrieveImageInMemoryCache(forKey: key) { return image }
        return await withCheckedContinuation { continuation in
            cache.retrieveImageInDiskCache(forKey: key, callbackQueue: .mainCurrentOrAsync) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    private func cachedImage(forKey key: String, in imageCache: ImageCache? = nil) -> UIImage? {
        let imageCache = imageCache ?? cache
        if let image = imageCache.retrieveImageInMemoryCache(forKey: key) { return image }
        // The default unprocessed Kingfisher key/serializer is used on write.
        // Warm Kingfisher memory directly, without an asynchronous callback hop.
        guard let data = try? imageCache.diskStorage.value(forKey: key),
              let image = UIImage(data: data) else { return nil }
        imageCache.store(image, forKey: key, toDisk: false)
        return image
    }

    private func enqueue(_ url: URL, forKey key: String, isVisible: Bool) {
        if var existing = requests[key] {
            existing.latestURL = url
            existing.isVisible = existing.isVisible || isVisible
            requests[key] = existing
            if isVisible && !existing.isActive {
                pendingKeys.removeAll { $0 == key }
                pendingKeys.insert(key, at: 0)
            }
        } else {
            requests[key] = Request(id: UUID(), latestURL: url, isVisible: isVisible)
            if isVisible { pendingKeys.insert(key, at: 0) }
            else { pendingKeys.append(key) }
        }
        drainDownloads()
    }

    private func drainDownloads() {
        while requests.values.filter(\.isActive).count < maximumConcurrentDownloads && !pendingKeys.isEmpty {
            let key = pendingKeys.removeFirst()
            guard var request = requests[key], !request.isActive else { continue }
            request.isActive = true
            requests[key] = request
            download(request.latestURL, forKey: key, request: request)
        }
    }

    private func finish(_ request: Request, forKey key: String, completedURL: URL) {
        requests.removeValue(forKey: key)
        if request.latestURL != completedURL {
            enqueue(request.latestURL, forKey: key, isVisible: request.isVisible)
        } else {
            drainDownloads()
        }
    }

    private func download(_ url: URL, forKey key: String, request: Request) {
        requests[key] = request
        downloader.downloadImage(with: url, options: [
            .processor(DownsamplingImageProcessor(size: CGSize(width: 256, height: 256))), .backgroundDecode,
            .downloadPriority(request.isVisible ? 1 : 0.25)
        ]) { [weak self] result in
            Task { @MainActor in
                guard let self, let current = self.requests[key], current.id == request.id else { return }
                guard current.latestURL == url else {
                    self.finish(current, forKey: key, completedURL: url)
                    return
                }
                switch result {
                case .failure:
                    self.failedRequests[key] = (url, Date())
                    self.finish(current, forKey: key, completedURL: url)
                    // Keep the previous cached image or placeholder on failure.
                case .success(let value):
                    // Hold the user's request until disk persistence finishes,
                    // preventing overlapping writes to the same stable key.
                    self.cache.store(value.image, forKey: key, callbackQueue: .mainCurrentOrAsync) { [weak self] stored in
                        Task { @MainActor in
                            guard let self, let latest = self.requests[key], latest.id == request.id else { return }
                            guard latest.latestURL == url else {
                                self.finish(latest, forKey: key, completedURL: url)
                                return
                            }
                            if case .success = stored.diskCacheResult {
                                self.defaults.set(self.revision(url), forKey: self.revisionKey(key))
                            }
                            self.failedRequests.removeValue(forKey: key)
                            for view in self.bindings.keyEnumerator().allObjects.compactMap({ $0 as? UIImageView }) {
                                if self.bindings.object(forKey: view)?.key == key { view.image = value.image }
                            }
                            self.finish(latest, forKey: key, completedURL: url)
                        }
                    }
                }
            }
        }
    }

    // Persist only source digests, not signed URLs, image files, or dialogs.
    private func revisionKey(_ key: String) -> String { "imim.avatar.source." + digest(key) }
    private func revision(_ url: URL) -> String { digest(url.absoluteString) }
    private func digest(_ value: String) -> String {
        // Keep persisted keys/revisions byte-for-byte compatible; only remove
        // the 32 Foundation formatting calls and intermediate strings.
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            bytes.append(Self.hexadecimalDigits[Int(byte >> 4)])
            bytes.append(Self.hexadecimalDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func placeholderImage(size: CGSize, name: String?, isGroup: Bool) -> UIImage {
        let side = max(size.width, size.height, 48)
        let first = isGroup ? nil : name?.trimmingCharacters(in: .whitespacesAndNewlines).first
        let format = UIGraphicsImageRendererFormat.default()
        let traits = UITraitCollection.current
        // Dynamic palette and font fallback must not reuse another appearance.
        // Store only an initial, never a full nickname or an avatar URL.
        let key = [String(describing: side), String(describing: format.scale),
                   String(format.preferredRange.rawValue), String(traits.userInterfaceStyle.rawValue),
                   String(traits.accessibilityContrast.rawValue), String(traits.userInterfaceLevel.rawValue),
                   String(traits.displayGamut.rawValue), String(traits.legibilityWeight.rawValue),
                   Locale.current.identifier, Locale.preferredLanguages.joined(separator: ","),
                   isGroup ? "group" : "person", first.map(String.init) ?? ""].joined(separator: "|") as NSString
        if let image = placeholders.object(forKey: key) { return image }
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let colors = isGroup
                ? [UIColor(DoveTheme.green).cgColor, UIColor.systemTeal.cgColor]
                : [UIColor(DoveTheme.greenSoft).cgColor, UIColor(DoveTheme.warmGray).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            if !isGroup, let first {
                let text = String(first) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: side * 0.38, weight: .semibold),
                    .foregroundColor: UIColor(DoveTheme.green)
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2), withAttributes: attributes)
            } else {
                let config = UIImage.SymbolConfiguration(pointSize: side * 0.38, weight: .semibold)
                let symbol = UIImage(systemName: isGroup ? "person.2.fill" : "person.fill", withConfiguration: config)?
                    .withTintColor(isGroup ? .white : UIColor(DoveTheme.green), renderingMode: .alwaysOriginal)
                symbol?.draw(in: CGRect(x: side * 0.25, y: side * 0.25, width: side * 0.5, height: side * 0.5))
            }
        }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        placeholders.setObject(image, forKey: key, cost: cost)
        return image
    }
}

@MainActor
func loadAvatar(urlString: String?, userId: String? = nil, into imageView: UIImageView) {
    AvatarImageLoader.loadAvatar(urlString: urlString, userId: userId, into: imageView)
}

/// Derive identity from existing persisted participants, without a model change.
extension Chat {
    var avatarPeerUserId: String? {
        guard type == "private" else { return nil }
        if isOfficial || isBot { return chatId }
        guard let currentId = UserDefaults.standard.string(forKey: "current_user_id") else { return nil }
        return memberIds.first { !$0.isEmpty && $0 != currentId && $0 != "me" }
    }
}
