// The actual pipeline/model are compiled with a unique cache name; App defaults
// and existing caches are never changed. The second process cannot fetch data.
extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
struct MomentFeedItem { let media: [MomentMediaItem] }
func momentURL(_ source: String?) -> URL? { source.flatMap(URL.init(string:)) }
@MainActor enum MomentFixtureOwner { static var value = "fixture-owner" }
actor ProxySession {
    static let shared = ProxySession()
    private var data: Data?
    private(set) var calls = 0
    func set(_ data: Data) { self.data = data }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        calls += 1
        guard let data else { throw URLError(.notConnectedToInternet) }
        try await Task.sleep(for: .milliseconds(25))
        return (data, HTTPURLResponse(url:request.url!, statusCode:200, httpVersion:nil,
                                     headerFields:["Content-Type":"image/jpeg"])!)
    }
}
@main @MainActor
struct MomentsImageCacheRegression {
    static var checks = 0
    static func check(_ condition: Bool, _ note: String) { precondition(condition, note); checks += 1 }
    static func success(_ phase: AsyncImagePhase) -> Bool { if case .success = phase { return true }; return false }
    static func empty(_ phase: AsyncImagePhase) -> Bool { if case .empty = phase { return true }; return false }
    static func main() async throws {
        let restore = CommandLine.arguments.contains("--restore")
        let url = URL(string:"https://fixture.invalid/photo.jpg?revision=1")!
        let owner = MomentFixtureOwner.value
        let model = MomentImageModel()
        if !restore {
            let jpg = UIGraphicsImageRenderer(size:CGSize(width:4000, height:3000), format: {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; return format
            }()).jpegData(withCompressionQuality:0.85) { context in
                UIColor.systemGreen.setFill(); context.fill(CGRect(x:0,y:0,width:4000,height:3000))
            }
            await ProxySession.shared.set(jpg)
        }
        await model.load(url:url, owner:owner, pixels:720)
        check(success(model.currentPhase(url:url, owner:owner, pixels:720)), "network or second-process disk hit displays image")
        let image = MomentImagePipeline.cache.retrieveImageInMemoryCache(
            forKey:MomentMediaPolicy.key(url:url,owner:owner), options:MomentImagePipeline.options(pixels:720))!
        check(image.size.width <= 720 && image.size.height <= 720, "actual Kingfisher downsample bound")
        let cg = image.cgImage!
        print("Actual Kingfisher fixture raster: \(cg.width)x\(cg.height), \(cg.bytesPerRow * cg.height) bytes; full RGBA reference 48000000 bytes")
        check(cg.bytesPerRow * cg.height < 48_000_000 / 20, "raster substantially smaller than original")
        check(MomentImagePipeline.cache.memoryStorage.config.totalCostLimit == 48 * 1024 * 1024, "memory budget")
        check(MomentImagePipeline.cache.diskStorage.config.sizeLimit == 160 * 1024 * 1024, "disk budget")
        let diskPath = MomentImagePipeline.cache.cachePath(forKey:MomentMediaPolicy.key(url:url,owner:owner),
            processorIdentifier:DownsamplingImageProcessor(size:CGSize(width:720,height:720)).identifier)
        check(FileManager.default.fileExists(atPath:diskPath), "processed disk image persisted")
        let memory = MomentImageModel()
        await memory.load(url:url, owner:owner, pixels:720)
        check(success(memory.phase), "memory hit displays immediately")
        check(await ProxySession.shared.calls == (restore ? 0 : 1), "cache hit avoids transport; restore is offline")
        check(empty(model.currentPhase(url:URL(string:"https://fixture.invalid/photo.jpg?revision=2")!, owner:owner, pixels:720)), "URL change cannot display old image")
        check(empty(model.currentPhase(url:url, owner:"different-owner", pixels:720)), "account change cannot display old image")
        check(empty(model.currentPhase(url:url, owner:owner, pixels:2048)), "viewer size uses separate raster")
        model.reset()
        check(empty(model.phase), "disappear releases presentation image")
        if !restore {
            let delayed = MomentImageModel()
            let pending = Task { await delayed.load(url:URL(string:"https://fixture.invalid/late.jpg")!, owner:owner, pixels:720) }
            try await Task.sleep(for:.milliseconds(5))
            delayed.reset(); pending.cancel(); await pending.value
            check(empty(delayed.phase), "cancelled/reset row cannot publish late result")
            MomentFixtureOwner.value = "different-owner"
            await delayed.load(url:url, owner:owner, pixels:720)
            check(empty(delayed.phase), "stale account cannot use even memory hit")
        } else {
            // Only this UUID-namespaced test cache is cleared after both processes.
            await MomentImagePipeline.cache.clearDiskCache()
            MomentImagePipeline.cache.clearMemoryCache()
        }
        print("PASS: \(checks) actual Kingfisher/presentation checks (\(restore ? "second process, disk-only" : "synthetic network/memory/cancellation")); no SwiftUI scroll or phone timing claims")
    }
}
