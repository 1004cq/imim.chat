#if AVATAR_PREFETCH_TESTS
// Standalone Mac Catalyst harness, intentionally not in the production target.
// Compile with AvatarImageLoader, AvatarStore, Models, DoveTheme and Kingfisher.
// Run --namespace <unique-id>, then repeat with --restore in another process.
import Kingfisher
import UIKit

private final class PrefetchURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in PrefetchServer.shared.receive(self) }
    }
    override func stopLoading() {}
}

@MainActor private final class PrefetchServer {
    static let shared = PrefetchServer()
    var order: [String] = []
    var pending: [String: [URLProtocol]] = [:]
    var peak = 0
    func receive(_ request: URLProtocol) {
        let url = request.request.url!.absoluteString
        order.append(url)
        pending[url, default: []].append(request)
        peak = max(peak, pending.values.reduce(0) { $0 + $1.count })
    }
    func count(_ url: String) -> Int { order.filter { $0 == url }.count }
    func respond(_ url: String, color: UIColor?, status: Int = 200) {
        let data = color.map { fixture($0).pngData()! } ?? Data()
        for request in pending.removeValue(forKey: url) ?? [] {
            let response = HTTPURLResponse(url: request.request.url!, statusCode: status,
                                          httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: data)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }
}

@MainActor private func fixture(_ color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }
}

@MainActor private func pixel(_ image: UIImage?) -> [UInt8] {
    guard let image = image?.cgImage else { return [] }
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes {
        let context = CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
}

@MainActor private final class WeakLoader {
    weak var value: AvatarImageLoader?
    init(_ value: AvatarImageLoader?) { self.value = value }
}

@MainActor private final class PrefetchRunner {
    let cache: ImageCache
    let downloader: ImageDownloader
    let defaults: UserDefaults
    let server = PrefetchServer.shared
    var checks = 0
    let a = "https://avatars.example.invalid/prefetch-a.png?v=1"
    let updatedA = "https://avatars.example.invalid/prefetch-a.png?v=2"
    let finalA = "https://avatars.example.invalid/prefetch-a.png?v=3"
    let b = "https://avatars.example.invalid/prefetch-b.png"
    let c = "https://avatars.example.invalid/prefetch-c.png"
    let d = "https://avatars.example.invalid/prefetch-d.png"

    init(namespace: String) {
        cache = ImageCache(name: "imim-prefetch-regression-\(namespace)")
        defaults = UserDefaults(suiteName: "imim-prefetch-regression-\(namespace)")!
        downloader = ImageDownloader(name: "imim-prefetch-regression-\(namespace)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrefetchURLProtocol.self]
        downloader.sessionConfiguration = config
    }
    func check(_ value: Bool, _ description: String) {
        guard value else { print("FAIL: \(description)"); exit(1) }
        checks += 1
        print("PASS: \(description)")
    }
    // Bounded condition polling, not a fixed delay deciding which task wins.
    func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "PrefetchTest", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "condition timed out; order=\(server.order)"])
    }
    func view() -> UIImageView { UIImageView(frame: CGRect(x: 0, y: 0, width: 56, height: 56)) }
    func run(restore: Bool) async throws {
        let loader = AvatarImageLoader(cache: cache, downloader: downloader, defaults: defaults,
                                       maximumConcurrentDownloads: 2)
        if restore {
            check(cache.retrieveImageInMemoryCache(forKey: "a") == nil, "new process starts without memory avatar")
            loader.prefetch([.init(userId: "a", urlString: a)], allowsSourceUpdates: false)
            try await wait { self.cache.retrieveImageInMemoryCache(forKey: "a") != nil }
            check(server.order.isEmpty, "cold historical snapshot cannot redownload an old avatar URL")
            let historical = view()
            loader.load(urlString: a, userId: "a", allowsSourceUpdates: false, into: historical)
            check(pixel(historical.image) == pixel(fixture(.orange)), "cold historical feed retains the latest disk avatar")
            loader.prefetch([.init(userId: "a", urlString: finalA), .init(userId: "b", urlString: b)])
            try await wait { self.cache.retrieveImageInMemoryCache(forKey: "a") != nil && self.cache.retrieveImageInMemoryCache(forKey: "b") != nil }
            check(server.order.isEmpty, "disk prewarming does not request unchanged URLs")
            let avatar = view()
            loader.load(urlString: finalA, userId: "a", into: avatar)
            check(pixel(avatar.image) == pixel(fixture(.orange)), "prewarmed cold avatar displays immediately")
        } else {
            loader.prefetch([.init(userId: "a", urlString: a), .init(userId: "a", urlString: a)])
            try await wait { self.server.count(self.a) == 1 }
            check(server.count(a) == 1, "off-screen avatar downloads without creating a view and duplicate prefetch merges")
            loader.prefetch([.init(userId: "b", urlString: b)])
            try await wait { self.server.count(self.b) == 1 }
            loader.prefetch([.init(userId: "c", urlString: c), .init(userId: "d", urlString: d)])
            let visibleD = view()
            loader.load(urlString: d, userId: "d", into: visibleD)
            check(server.order.count == 2, "prefetch plus visible requests respect concurrency limit")
            loader.prefetch([.init(userId: "a", urlString: updatedA)])
            server.respond(a, color: .red)
            try await wait { self.server.count(self.d) == 1 }
            check(server.order[2] == d, "visible avatar promoted ahead of off-screen queue")
            check(cache.retrieveImageInMemoryCache(forKey: "a") == nil, "superseded prefetch cannot cache the old URL")
            server.respond(b, color: .green)
            try await wait { self.server.count(self.c) == 1 }
            server.respond(d, color: .blue)
            try await wait { self.server.count(self.updatedA) == 1 }
            server.respond(c, color: .cyan)
            server.respond(updatedA, color: .purple)
            try await wait { self.cache.retrieveImageInMemoryCache(forKey: "a") != nil && pixel(visibleD.image) == pixel(fixture(.blue)) }
            check(server.peak <= 2, "active network requests never exceed configured limit")
            let visibleA = view(), visibleB = view()
            loader.load(urlString: updatedA, userId: "a", into: visibleA)
            loader.load(urlString: b, userId: "b", into: visibleB)
            check(pixel(visibleA.image) == pixel(fixture(.purple)), "prefetched avatar displays synchronously on first appearance")
            check(pixel(visibleB.image) == pixel(fixture(.green)), "another prefetched user displays synchronously")
            let requestCount = server.order.count
            loader.prefetch([.init(userId: "a", urlString: updatedA), .init(userId: "b", urlString: b)])
            check(server.order.count == requestCount, "memory hits do not launch another prefetch")
            loader.prefetch([.init(userId: "a", urlString: a)], allowsSourceUpdates: false)
            let historical = view()
            loader.load(urlString: a, userId: "a", allowsSourceUpdates: false, into: historical)
            check(pixel(historical.image) == pixel(fixture(.purple)), "historical Moments avatar uses latest cached user image")
            check(server.count(a) == 1, "historical source cannot download or restore stale URL")
            loader.prefetch([.init(userId: "a", urlString: finalA)])
            loader.load(urlString: finalA, userId: "a", into: visibleA)
            try await wait { self.server.count(self.finalA) == 1 }
            check(pixel(visibleA.image) == pixel(fixture(.purple)), "changed prefetched URL retains old avatar until ready")
            loader.load(urlString: b, userId: "b", into: historical)
            server.respond(finalA, color: .orange)
            try await wait { pixel(visibleA.image) == pixel(fixture(.orange)) }
            check(server.count(finalA) == 1, "visible and background downloads for the same user merge")
            check(pixel(historical.image) == pixel(fixture(.green)), "recycled view rejects completion from previous user")
            check(pixel(visibleB.image) == pixel(fixture(.green)), "avatar replacement leaves other user's image untouched")
            let failedURL = "https://avatars.example.invalid/prefetch-a.png?failed=1"
            loader.prefetch([.init(userId: "a", urlString: failedURL)])
            try await wait { self.server.count(failedURL) == 1 }
            server.respond(failedURL, color: nil, status: 503)
            // Use another completed job as a queue progress barrier.
            let next = "https://avatars.example.invalid/after-failure.png"
            loader.prefetch([.init(userId: "next", urlString: next)])
            try await wait { self.server.count(next) == 1 }
            server.respond(next, color: .yellow)
            try await wait { self.cache.retrieveImageInMemoryCache(forKey: "next") != nil }
            check(pixel(visibleA.image) == pixel(fixture(.orange)), "failed prefetch preserves previous avatar")
            loader.prefetch([.init(userId: "a", urlString: failedURL)])
            check(server.count(failedURL) == 1, "failed source is throttled instead of a retry loop")
            loader.prefetch([.init(userId: "a", urlString: finalA)])
            check(server.count(finalA) == 1, "restoring authoritative cached source needs no new download")
            let countBeforeInvalid = server.order.count
            loader.prefetch([.init(userId: nil, urlString: nil), .init(userId: "asset", urlString: "asset://ImimOfficialAvatar")])
            check(server.order.count == countBeforeInvalid, "empty and bundled avatars do not hit network")
            var disposable: AvatarImageLoader? = AvatarImageLoader(cache: cache, downloader: downloader,
                                                                   defaults: defaults)
            let weakLoader = WeakLoader(disposable)
            disposable?.prefetch([.init(userId: "b", urlString: b)])
            disposable = nil
            check(weakLoader.value == nil, "background prefetch does not retain loader owner")
        }
        print("PREFETCH REGRESSION: \(checks) checks passed; restore=\(restore)")
    }
}

@main private struct AvatarPrefetchRegression {
    @MainActor static func main() async {
        do {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--namespace"), args.indices.contains(index + 1) else { exit(2) }
            try await PrefetchRunner(namespace: args[index + 1]).run(restore: args.contains("--restore"))
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
#endif
