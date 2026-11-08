// Actual feed loading methods and video cache are extracted by the runner.
// Network and feed values below are fixtures. No App account/defaults are used.
extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
struct MomentFeedItem: Identifiable, Sendable {
    let id: String
}
struct MomentFeedResponse: Sendable {
    let moments: [MomentFeedItem]
    let nextCursor: String?
    let hasMore: Bool?
}
@MainActor enum MomentImagePipeline {
    static var owner = "fixture-A"
    static var prefetchCount = 0
    static var prefetchBatches: [[String]] = []
    static func prefetch(_ items: [MomentFeedItem]) { prefetchCount += 1; prefetchBatches.append(items.map(\.id)) }
}
actor ProxySession {
    static let shared = ProxySession()
    func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw URLError(.notConnectedToInternet) }
    func download(for request: URLRequest) async throws -> (URL, URLResponse) { throw URLError(.notConnectedToInternet) }
}
actor APIClient {
    static let shared = APIClient()
    var count = 0
    private var pending: [Int: CheckedContinuation<MomentFeedResponse, Error>] = [:]
    func fetchMomentsFeed(cursor: String? = nil) async throws -> MomentFeedResponse {
        count += 1
        let id = count
        // Deliberately ignores cancellation: guards must reject even late success.
        return try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func complete(_ id: Int, ids: [String], more: Bool = false) {
        pending.removeValue(forKey: id)!.resume(returning: .init(
            moments: ids.map { .init(id: $0) }, nextCursor: more ? "cursor" : nil, hasMore: more))
    }
    func fail(_ id: Int, error: any Error = URLError(.timedOut)) { pending.removeValue(forKey: id)!.resume(throwing: error) }
}
#if !FEED_BASELINE
actor VideoFixture {
    var calls = 0
    var status = 200
    var mime = "video/mp4"
    var delay: Duration = .milliseconds(15)
    func transfer(_ request: URLRequest) async throws -> (URL, URLResponse) {
        calls += 1
        try await Task.sleep(for: delay)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-video-\(UUID()).mp4")
        // Synthetic cache bytes, not a playable movie. AVPlayer UI needs device tests.
        try Data("fixture-version-\(calls)".utf8).write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: status,
                                     httpVersion: nil, headerFields: ["Content-Type":mime])!)
    }
    func setStatus(_ value: Int) { status = value }
    func setDelay(_ value: Duration) { delay = value }
    func setMIME(_ value: String) { mime = value }
}
#endif
@main @MainActor
struct MomentsBugfixRegression {
    static var checks = 0
    static func check(_ value: Bool, _ note: String) {
        guard value else { fatalError("FAIL: \(note)") }
        checks += 1
    }
    static func waitForRequest(_ count: Int) async throws {
        for _ in 0..<500 {
            if await APIClient.shared.count == count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        fatalError("request did not reach fixture")
    }
    static func main() async throws {
        let model = MomentsFeedViewModel()
        let first = Task { await model.refresh() }
        try await waitForRequest(1)
        let newer = Task { await model.refresh() }
        try await waitForRequest(2)
        await APIClient.shared.complete(2, ids: ["new", "new"], more: true)
        await newer.value
        check(model.moments.map(\.id) == ["new"], "latest refresh publishes")
        check(MomentImagePipeline.prefetchBatches.last == ["new"], "first-page duplicate IDs do not duplicate prefetch input")
        await APIClient.shared.complete(1, ids: ["old"])
        await first.value
        check(model.moments.map(\.id) == ["new"], "late refresh cannot overwrite new feed")
        check(model.hasMore && !model.isLoading, "late response cannot change cursor or loading")

        let page = Task { await model.loadMore() }
        try await waitForRequest(3)
        let refresh = Task { await model.refresh() }
        try await waitForRequest(4)
        check(!model.isLoadingMore, "new refresh invalidates old pagination flag")
        await model.loadMore()
        check(await APIClient.shared.count == 4, "pagination blocked during refresh")
        await APIClient.shared.complete(4, ids: ["fresh"], more: true)
        await refresh.value
        await APIClient.shared.complete(3, ids: ["old-page"])
        await page.value
        check(model.moments.map(\.id) == ["fresh"], "old cursor page cannot append after refresh")
        check(model.hasMore, "old page cannot remove new cursor")
        let validPage = Task { await model.loadMore() }
        try await waitForRequest(5)
        await APIClient.shared.complete(5, ids: ["fresh", "next", "next"])
        await validPage.value
        check(model.moments.map(\.id) == ["fresh", "next"], "current page merges without duplicates")
        check(MomentImagePipeline.prefetchBatches.last == ["next"], "pagination prefetches only newly appended items")

        let cancelled = Task { await model.refresh() }
        try await waitForRequest(6)
        cancelled.cancel()
        await APIClient.shared.complete(6, ids: ["cancelled"])
        await cancelled.value
        check(model.moments.map(\.id) == ["fresh", "next"], "cancelled late success is not published")
        check(model.errorMessage == nil && !model.isLoading, "cancellation clears busy state without error")

        let switched = Task { await model.refresh() }
        try await waitForRequest(7)
        MomentImagePipeline.owner = "fixture-B"
        let prefetch = MomentImagePipeline.prefetchCount
        await APIClient.shared.complete(7, ids: ["other-account"])
        await switched.value
        check(model.moments.map(\.id) == ["fresh", "next"], "late old-account response rejected")
        check(MomentImagePipeline.prefetchCount == prefetch, "old-account response cannot prefetch under new owner")
        let oldFailure = Task { await model.refresh() }
        try await waitForRequest(8)
        let newest = Task { await model.refresh() }
        try await waitForRequest(9)
        await APIClient.shared.fail(8)
        await oldFailure.value
        check(model.isLoading && model.errorMessage == nil, "old failure cannot stop newer loading or show stale error")
        await APIClient.shared.complete(9, ids: ["B"])
        await newest.value
        check(model.moments.map(\.id) == ["B"] && !model.isLoading, "new owner can still refresh")
        let failure = Task { await model.refresh() }
        try await waitForRequest(10)
        await APIClient.shared.fail(10)
        await failure.value
        check(model.errorMessage != nil && !model.isLoading, "current failure is shown and retry remains possible")
        for (offset, error) in [CancellationError() as any Error, URLError(.cancelled) as any Error].enumerated() {
            let request = 11 + offset
            let refresh = Task { await model.refresh() }
            try await waitForRequest(request)
            await APIClient.shared.fail(request, error: error)
            await refresh.value
            check(model.errorMessage == nil && !model.isLoading, "uncancelled caller's cancelled transport is silent")
        }
        let preparePage = Task { await model.refresh() }
        try await waitForRequest(13)
        await APIClient.shared.complete(13, ids: ["B"], more: true)
        await preparePage.value
        for (offset, error) in [CancellationError() as any Error, URLError(.cancelled) as any Error].enumerated() {
            let request = 14 + offset
            let page = Task { await model.loadMore() }
            try await waitForRequest(request)
            await APIClient.shared.fail(request, error: error)
            await page.value
            check(model.errorMessage == nil && !model.isLoadingMore && model.hasMore, "page cancellation preserves retry cursor without red error")
        }
        print("PASS: \(checks) actual feed loading checks (late refresh/page, cancellation, owner and error isolation)")

        #if !FEED_BASELINE
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moments-video-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = VideoFixture()
        let cache = MomentVideoAssetCache(directory: root) { try await fixture.transfer($0) }
        let url = URL(string:"https://fixture.invalid/a.mp4?v=1")!
        let player = try await cache.playerFile(for: url, owner: "A")
        defer { try? FileManager.default.removeItem(at: player) }
        let original = await cache.cachedFile(for: url, owner: "A")!
        check(await fixture.calls == 1 && original != player, "one download with player-owned file")
        check(try Data(contentsOf: player) == Data(contentsOf: original), "player bytes match cache")
        await cache.invalidate(url, owner: "A", failedFile: player)
        check(await cache.cachedFile(for: url, owner: "A") == nil, "broken cache entry removed")
        check(FileManager.default.fileExists(atPath: player.path), "eviction does not destroy active player file")
        let replacement = try await cache.playerFile(for: url, owner: "A")
        defer { try? FileManager.default.removeItem(at: replacement) }
        check(await fixture.calls == 2, "explicit retry downloads new bytes")
        await cache.invalidate(url, owner: "A", failedFile: player)
        check(await cache.cachedFile(for: url, owner: "A") != nil, "late old-player failure preserves replacement")
        let other = try await cache.playerFile(for: url, owner: "B")
        defer { try? FileManager.default.removeItem(at: other) }
        await cache.invalidate(url, owner: "A", failedFile: other)
        check(await cache.cachedFile(for: url, owner: "A") != nil, "other-account file cannot evict current entry")
        let url2 = URL(string:"https://fixture.invalid/a.mp4?v=2")!
        let revised = try await cache.playerFile(for: url2, owner: "A")
        defer { try? FileManager.default.removeItem(at: revised) }
        await cache.invalidate(url, owner: "A", failedFile: revised)
        check(await cache.cachedFile(for: url, owner: "A") != nil, "other URL revision cannot evict entry")
        await cache.invalidate(url, owner: "A", failedFile: root.appendingPathComponent("missing.mp4"))
        check(await cache.cachedFile(for: url, owner: "A") != nil, "missing failure metadata cannot evict entry")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-copy-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: copy) }
        let cachedReplacement = await cache.cachedFile(for: url, owner: "A")!
        try FileManager.default.copyItem(at: cachedReplacement, to: copy)
        let attributes = try FileManager.default.attributesOfItem(atPath: cachedReplacement.path)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: copy.path)
        await cache.invalidate(url, owner: "A", failedFile: copy)
        check(await cache.cachedFile(for: url, owner: "A") == nil, "copy fallback invalidates matching bad cached bytes")
        let mergedURL = URL(string:"https://fixture.invalid/merged.mp4")!
        let before = await fixture.calls
        let owned = try await withThrowingTaskGroup(of: URL.self, returning: [URL].self) { group in
            for _ in 0..<8 { group.addTask { try await cache.playerFile(for: mergedURL, owner: "A") } }
            var files: [URL] = []
            for try await value in group { files.append(value) }
            return files
        }
        defer { for file in owned { try? FileManager.default.removeItem(at: file) } }
        check(await fixture.calls == before + 1 && Set(owned).count == 8, "leases merge download but own playback files")
        await fixture.setStatus(503)
        let failedURL = URL(string:"https://fixture.invalid/failed.mp4")!
        do { _ = try await cache.playerFile(for: failedURL, owner:"A"); check(false, "HTTP error") }
        catch { check(await cache.cachedFile(for: failedURL, owner:"A") == nil, "failed HTTP cannot enter cache") }
        await fixture.setStatus(200)
        let recovered = try await cache.playerFile(for: failedURL, owner: "A")
        defer { try? FileManager.default.removeItem(at: recovered) }
        check(FileManager.default.fileExists(atPath: recovered.path), "retry after HTTP failure recovers")
        let cancelledURL = URL(string:"https://fixture.invalid/cancelled.mp4")!
        let cancelledVideo = Task { try await cache.playerFile(for: cancelledURL, owner:"A") }
        cancelledVideo.cancel()
        do { _ = try await cancelledVideo.value; check(false, "cancelled playback") }
        catch { check(await cache.cachedFile(for: cancelledURL, owner:"A") == nil, "cancelled playback has no cache file") }

        let limitedRoot = root.appendingPathComponent("deadline")
        let slow = VideoFixture()
        await slow.setDelay(.seconds(2))
        let limited = MomentVideoAssetCache(directory: limitedRoot, timeout: .milliseconds(25)) { try await slow.transfer($0) }
        do { _ = try await limited.playerFile(for: url, owner: "A"); check(false, "slow complete transfer must stop") }
        catch { check((error as? URLError)?.code == .timedOut, "cache enforces total transfer deadline") }
        check(await limited.cachedFile(for: url, owner: "A") == nil, "timeout does not cache partial video")
        await slow.setDelay(.zero)
        let retried = try await limited.playerFile(for: url, owner: "A")
        defer { try? FileManager.default.removeItem(at: retried) }
        check(FileManager.default.fileExists(atPath: retried.path), "timeout releases coalescing job and admission slot for retry")

        await fixture.setMIME("text/html")
        let htmlURL = URL(string:"https://fixture.invalid/login.mp4")!
        do { _ = try await cache.playerFile(for: htmlURL, owner:"A"); check(false, "HTML is not video") }
        catch {
            if case MomentVideoLoadError.unsupportedContent = error { check(true, "non-video success response has specific error") }
            else { check(false, "wrong content error") }
        }
        await fixture.setMIME("video/mp4")
        await fixture.setStatus(206)
        let partialURL = URL(string:"https://fixture.invalid/partial.mp4")!
        do { _ = try await cache.playerFile(for: partialURL, owner:"A"); check(false, "partial response is not complete cached movie") }
        catch { check(await cache.cachedFile(for: partialURL, owner:"A") == nil, "unexpected partial response cannot poison full-file cache") }
        print("PASS: \(checks) total actual feed/video-cache checks; strict Swift 6; synthetic bytes only, no AVPlayer runtime claim")
        #endif
    }
}
