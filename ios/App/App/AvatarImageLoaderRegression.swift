#if AVATAR_REGRESSION_TESTS
// Standalone simulator/Mac Catalyst harness; not part of the App target. Compile together
// with AvatarImageLoader, DoveTheme, AvatarStore, Models and Kingfisher 8.12.
// Launch with a unique namespace, then relaunch with the same namespace and
// --restore to test genuinely cold memory/SwiftData recovery across processes.
import Kingfisher
import SwiftData
import UIKit

private final class AvatarStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in AvatarStubServer.shared.receive(self) }
    }
    override func stopLoading() {}
}

@MainActor
private final class AvatarStubServer {
    static let shared = AvatarStubServer()
    var received: [String: Int] = [:]
    var pending: [String: [URLProtocol]] = [:]

    func receive(_ request: URLProtocol) {
        let key = request.request.url!.absoluteString
        received[key, default: 0] += 1
        pending[key, default: []].append(request)
    }

    func respond(_ url: String, color: UIColor?, status: Int = 200) {
        let data = color.map { solid($0).pngData()! } ?? Data()
        for request in pending.removeValue(forKey: url) ?? [] {
            let response = HTTPURLResponse(url: request.request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "image/png"])!
            request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
            request.client?.urlProtocol(request, didLoad: data)
            request.client?.urlProtocolDidFinishLoading(request)
        }
    }
}

@MainActor
private func solid(_ color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    }
}

@MainActor
private func pixel(_ image: UIImage?) -> [UInt8] {
    guard let image = image?.cgImage else { return [] }
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes {
        let context = CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
}

@MainActor
private final class AvatarRegressionRunner {
    private var checks = 0
    private let aliceURL = "https://avatars.example.invalid/alice.png?v=1"
    private let updatedURL = "https://avatars.example.invalid/alice.png?v=2"
    private let finalURL = "https://avatars.example.invalid/alice.png?v=3"
    private let bobURL = "https://avatars.example.invalid/bob.png?v=1"
    private let namespace: String
    private let defaults: UserDefaults
    private let cache: ImageCache
    private let downloader: ImageDownloader
    private let container: ModelContainer
    private let server = AvatarStubServer.shared

    init(namespace: String) throws {
        self.namespace = namespace
        defaults = UserDefaults(suiteName: "imim.avatar.regression.\(namespace)")!
        cache = ImageCache(name: "imim-avatar-regression-\(namespace)")
        downloader = ImageDownloader(name: "imim-avatar-regression-\(namespace)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AvatarStubURLProtocol.self]
        downloader.sessionConfiguration = configuration
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer(for: Chat.self, Message.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("avatar-\(namespace).store")))
    }

    private func check(_ passed: Bool, _ label: String) {
        guard passed else { print("FAIL: \(label)"); exit(1) }
        checks += 1
        print("PASS: \(label)")
    }

    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "AvatarRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out"])
    }

    private func view() -> UIImageView {
        UIImageView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
    }

    func run(restore: Bool) async throws {
        let loader = AvatarImageLoader(cache: cache, downloader: downloader, defaults: defaults)
        if restore {
            let chats = try container.mainContext.fetch(FetchDescriptor<Chat>())
            check(chats.count == 2 && chats.contains { $0.name == "Alice 昵称" }, "SwiftData conversations/title restored before any API call")
            let a = view(), b = view()
            loader.load(urlString: finalURL, userId: "alice", name: "Alice", into: a)
            loader.load(urlString: bobURL, userId: "bob", name: "Bob", into: b)
            check(pixel(a.image) == pixel(solid(.blue)), "cold process: Alice disk hit shown synchronously")
            check(pixel(b.image) == pixel(solid(.green)), "cold process: Bob disk hit shown synchronously")
            try await Task.sleep(nanoseconds: 200_000_000)
            check(server.received.isEmpty, "cold process: unchanged URLs do not download")
        } else {
            check(AvatarImageLoader.cacheKey(userId: "alice", urlString: aliceURL) == "alice", "user ID is the cache key")
            check(AvatarImageLoader.cacheKey(userId: "alice", urlString: updatedURL) == "alice", "changed URL keeps the same user key")
            check(AvatarImageLoader.cacheKey(userId: nil, urlString: aliceURL) == "/alice.png", "fallback excludes the query")
            check(AvatarImageLoader.cacheKey(userId: nil, urlString: updatedURL) == "/alice.png", "query-only change preserves fallback key")

            let a = view(), secondAlice = view(), b = view()
            loader.load(urlString: aliceURL, userId: "alice", name: "Alice", into: a)
            check(a.image != nil, "uncached avatar shows an immediate placeholder")
            if case .none = a.kf.indicatorType {
                check(true, "loading avatars never show an activity indicator")
            } else { check(false, "loading avatars never show an activity indicator") }
            loader.load(urlString: aliceURL, userId: "alice", name: "Alice", into: secondAlice)
            loader.load(urlString: bobURL, userId: "bob", name: "Bob", into: b)
            try await wait { self.server.received[self.aliceURL] == 1 && self.server.received[self.bobURL] == 1 }
            server.respond(aliceURL, color: .red)
            server.respond(bobURL, color: .green)
            try await wait { pixel(a.image) == pixel(solid(.red)) && pixel(b.image) == pixel(solid(.green)) }
            check(server.received[aliceURL] == 1 && pixel(secondAlice.image) == pixel(a.image), "two same-user views share one download")

            let hit = view()
            loader.load(urlString: aliceURL, userId: "alice", name: "Alice", into: hit)
            check(pixel(hit.image) == pixel(solid(.red)), "memory hit is synchronous")
            check(server.received[aliceURL] == 1, "memory hit starts no extra request")

            loader.load(urlString: updatedURL, userId: "alice", name: "Alice", into: a)
            check(pixel(a.image) == pixel(solid(.red)), "URL change retains old image while downloading")
            try await wait { self.server.received[self.updatedURL] == 1 }
            loader.load(urlString: finalURL, userId: "alice", name: "Alice", into: a)
            loader.load(urlString: aliceURL, userId: "alice", name: "Alice", into: secondAlice)
            check(server.received[finalURL] == nil, "same user never has two simultaneous downloads")
            server.respond(updatedURL, color: .yellow)
            try await wait { self.server.received[self.finalURL] == 1 }
            check(pixel(a.image) == pixel(solid(.red)), "superseded download cannot overwrite the old image")
            server.respond(finalURL, color: .blue)
            try await wait { pixel(a.image) == pixel(solid(.blue)) }
            check(pixel(secondAlice.image) == pixel(a.image), "latest image updates all views of that user")
            check(pixel(b.image) == pixel(solid(.green)) && server.received[bobURL] == 1, "avatar update leaves other user unchanged")

            let recycled = view()
            loader.load(urlString: aliceURL, userId: "recycle", name: "Alice", into: recycled)
            loader.load(urlString: bobURL, userId: "bob", name: "Bob", into: recycled)
            try await wait { self.server.received[self.aliceURL] == 2 }
            server.respond(aliceURL, color: .red)
            try await Task.sleep(nanoseconds: 100_000_000)
            check(pixel(recycled.image) == pixel(solid(.green)), "recycled image view rejects previous user's completion")

            let failureURL = "https://avatars.example.invalid/alice.png?v=failed"
            loader.load(urlString: failureURL, userId: "alice", name: "Alice", into: a)
            try await wait { self.server.received[failureURL] == 1 }
            server.respond(failureURL, color: nil, status: 503)
            try await Task.sleep(nanoseconds: 100_000_000)
            check(pixel(a.image) == pixel(solid(.blue)), "download failure preserves the previous avatar")

            let local = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-local-\(namespace).png")
            try solid(.magenta).pngData()!.write(to: local, options: .atomic)
            let localView = view()
            let countBeforeLocal = server.received.values.reduce(0, +)
            loader.load(urlString: local.path, userId: "self", name: "Me", into: localView)
            check(pixel(localView.image) == pixel(solid(.magenta)), "own uploaded local file remains immediate")
            check(server.received.values.reduce(0, +) == countBeforeLocal, "own local avatar never requests the network")

            for (id, name, avatar) in [("alice", "Alice 昵称", finalURL), ("bob", "Bob", bobURL)] {
                container.mainContext.insert(Chat(chatId: "chat-\(id)", name: name, avatar: avatar, memberIds: ["test-me", id]))
            }
            try container.mainContext.save()
            check(cache.imageCachedType(forKey: "alice") == .memory, "latest avatar stored under the stable key")
        }
        print("AVATAR REGRESSION: \(checks) checks passed; namespace=\(namespace); restore=\(restore)")
    }
}

private final class AvatarRegressionDelegate: NSObject, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        Task { @MainActor in
            do {
                let args = ProcessInfo.processInfo.arguments
                guard let index = args.firstIndex(of: "--namespace"), args.indices.contains(index + 1) else {
                    print("FAIL: --namespace required"); exit(1)
                }
                let runner = try AvatarRegressionRunner(namespace: args[index + 1])
                try await runner.run(restore: args.contains("--restore"))
                exit(0)
            } catch { print("FAIL: \(error)"); exit(1) }
        }
        return true
    }
}

#if targetEnvironment(macCatalyst)
@main
private struct AvatarRegressionMain {
    @MainActor static func main() async {
        do {
            let args = ProcessInfo.processInfo.arguments
            guard let index = args.firstIndex(of: "--namespace"), args.indices.contains(index + 1) else {
                print("FAIL: --namespace required"); exit(1)
            }
            let runner = try AvatarRegressionRunner(namespace: args[index + 1])
            try await runner.run(restore: args.contains("--restore"))
        } catch { print("FAIL: \(error)"); exit(1) }
    }
}
#else
@main
private struct AvatarRegressionMain {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AvatarRegressionDelegate.self))
    }
}
#endif
#endif
