import CryptoKit
import Kingfisher
import SwiftUI
import UIKit

/// UI-owned coordination for SwiftUI and UIKit. Rows do not own downloads:
/// disappearing/recycling one row must not cancel another row's request.
@MainActor
final class AvatarImageLoader {
    static let shared = AvatarImageLoader()

    private final class Binding: NSObject {
        let key: String
        let url: URL?
        init(key: String, url: URL?) { self.key = key; self.url = url }
    }

    private struct Request {
        let id: UUID
        var latestURL: URL
    }

    private let cache: ImageCache
    private let downloader: ImageDownloader
    private let defaults: UserDefaults
    private let bindings = NSMapTable<UIImageView, Binding>.weakToStrongObjects()
    private var requests: [String: Request] = [:]
    private var latestSources: [String: URL] = [:]
    private var failedRequests: [String: (url: URL, date: Date)] = [:]

    init(
        cache: ImageCache = ImageCache(name: "IMIMPeerAvatars"),
        downloader: ImageDownloader = .default,
        defaults: UserDefaults = .standard
    ) {
        self.cache = cache
        self.downloader = downloader
        self.defaults = defaults
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
        let resolved = trimmed.hasPrefix("/") ? "https://wed.imim.chat\(trimmed)" : trimmed
        guard let url = URL(string: resolved),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func loadAvatar(
        urlString: String?, userId: String? = nil, name: String? = nil,
        isGroup: Bool = false, into imageView: UIImageView
    ) {
        shared.load(urlString: urlString, userId: userId, name: name, isGroup: isGroup, into: imageView)
    }

    func load(
        urlString: String?, userId: String? = nil, name: String? = nil,
        isGroup: Bool = false, into imageView: UIImageView
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

        guard let key = Self.cacheKey(userId: userId, urlString: urlString) else {
            imageView.image = Self.placeholderImage(size: imageView.bounds.size, name: name, isGroup: isGroup)
            return
        }
        let remoteURL = Self.remoteURL(from: urlString)
        bindings.setObject(Binding(key: key, url: remoteURL), forKey: imageView)

        // Read the small avatar for the first frame, including after process
        // restart. Network work never blocks this synchronous cache-only path.
        var image = cachedImage(forKey: key)
        if image == nil, let url = Self.remoteURL(from: urlString),
           let legacy = cachedImage(forKey: url.absoluteString, in: .default) {
            image = legacy
            cache.store(legacy, forKey: key)
        }
        imageView.image = image ?? Self.placeholderImage(size: imageView.bounds.size, name: name, isGroup: isGroup)

        guard let url = remoteURL else { return }
        // An unchanged, already bound row may still carry the old profile URL.
        // Its redraw must not undo a newer URL supplied by another surface.
        if previousBinding?.key == key, previousBinding?.url == url,
           let latest = latestSources[key], latest != url { return }
        latestSources[key] = url
        if var request = requests[key] {
            request.latestURL = url
            requests[key] = request
            return
        }
        if image != nil, defaults.string(forKey: revisionKey(key)) == revision(url) { return }
        if let failed = failedRequests[key], failed.url == url,
           Date().timeIntervalSince(failed.date) < 15 { return }
        download(url, forKey: key)
    }

    func unbind(_ imageView: UIImageView) { bindings.removeObject(forKey: imageView) }

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

    private func download(_ url: URL, forKey key: String) {
        let request = Request(id: UUID(), latestURL: url)
        requests[key] = request
        downloader.downloadImage(with: url, options: [
            .processor(DownsamplingImageProcessor(size: CGSize(width: 256, height: 256))), .backgroundDecode
        ]) { [weak self] result in
            Task { @MainActor in
                guard let self, let current = self.requests[key], current.id == request.id else { return }
                guard current.latestURL == url else {
                    self.requests.removeValue(forKey: key)
                    self.download(current.latestURL, forKey: key)
                    return
                }
                switch result {
                case .failure:
                    self.requests.removeValue(forKey: key)
                    self.failedRequests[key] = (url, Date())
                    // Keep the previous cached image or placeholder on failure.
                case .success(let value):
                    // Hold the user's request until disk persistence finishes,
                    // preventing overlapping writes to the same stable key.
                    self.cache.store(value.image, forKey: key, callbackQueue: .mainCurrentOrAsync) { [weak self] stored in
                        Task { @MainActor in
                            guard let self, let latest = self.requests[key], latest.id == request.id else { return }
                            self.requests.removeValue(forKey: key)
                            guard latest.latestURL == url else {
                                self.download(latest.latestURL, forKey: key)
                                return
                            }
                            if case .success = stored.diskCacheResult {
                                self.defaults.set(self.revision(url), forKey: self.revisionKey(key))
                            }
                            self.failedRequests.removeValue(forKey: key)
                            for view in self.bindings.keyEnumerator().allObjects.compactMap({ $0 as? UIImageView }) {
                                if self.bindings.object(forKey: view)?.key == key { view.image = value.image }
                            }
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
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func placeholderImage(size: CGSize, name: String?, isGroup: Bool) -> UIImage {
        let side = max(size.width, size.height, 48)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let colors = isGroup
                ? [UIColor(DoveTheme.green).cgColor, UIColor.systemTeal.cgColor]
                : [UIColor(DoveTheme.greenSoft).cgColor, UIColor(DoveTheme.warmGray).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            if !isGroup, let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first {
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
