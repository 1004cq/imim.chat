// Compiled with the actual policy, item model and scheduler extracted above.
extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
actor ProxySession {
    static let shared = ProxySession()
    var response: (Int, String)?
    var probeCalls = 0
    func configure(_ status: Int, _ mime: String) { response = (status, mime) }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        probeCalls += 1
        guard let response else { throw URLError(.notConnectedToInternet) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: response.0,
            httpVersion: nil, headerFields: ["Content-Type":response.1])!)
    }
}
enum AppServer { static let origin = "https://app.imim.chat" }
actor MomentFixtureCounter {
    var started = 0, active = 0, peak = 0, cancelled = 0
    func run(delay: Duration = .milliseconds(100), fail: Bool = false) async throws -> MomentMediaResponse {
        started += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        do { try await Task.sleep(for: delay) }
        catch { cancelled += 1; throw error }
        if fail { throw URLError(.badServerResponse) }
        return MomentMediaResponse(data: Data([1]), status: 200, mime: "image/jpeg", ranges: nil)
    }
}
actor MomentFixtureOrder {
    var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
@main @MainActor
struct MomentsMediaRegression {
    static var checks = 0
    static func check(_ value: Bool, _ note: String) { precondition(value, note); checks += 1 }
    static func item(_ values: [String: String]) throws -> MomentMediaItem {
        try JSONDecoder().decode(MomentMediaItem.self, from: JSONSerialization.data(withJSONObject: values))
    }
    static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        preconditionFailure("fixture did not reach expected state")
    }
    static func main() async throws {
        let url = URL(string: "https://app.imim.chat/media/a.mp4?q=1")!
        check(MomentMediaPolicy.photo(try item(["url":"original", "thumbUrl":"small", "mediumUrl":"medium"])) == "small", "thumbnail first")
        check(MomentMediaPolicy.photo(try item(["url":"original", "thumbUrl":" ", "mediumUrl":"medium"])) == "medium", "blank thumbnail fallback")
        check(MomentMediaPolicy.poster(try item(["url":"a.mp4", "posterUrl":" ", "thumbUrl":"poster.jpg"])) == "poster.jpg", "blank poster fallback")
        check(MomentMediaPolicy.poster(try item(["url":"a.mp4", "posterUrl":"a.mp4", "mediumUrl":"b.mov"])) == nil, "never treat video as poster")
        check(MomentMediaPolicy.poster(try item(["url":"/api/media/a", "posterUrl":"/api/media/a"])) == nil, "extensionless video is not its own poster")
        let first = MomentMediaPolicy.key(url: url, owner: "one")
        check(first != MomentMediaPolicy.key(url: url, owner: "two"), "account cache separation")
        check(first != MomentMediaPolicy.key(url: URL(string:"https://app.imim.chat/media/a.mp4?q=2")!, owner:"one"), "full URL revisions separated")
        check(!first.contains("q=1") && first.count == 75, "hashed keys do not expose signed URL")
        check(MomentMediaPolicy.mayStream(url: url, proxyEnabled: false, status:200, mime:"video/mp4", ranges:"bytes"), "advertised range stream")
        check(!MomentMediaPolicy.mayStream(url: url, proxyEnabled: true, status:200, mime:"video/mp4", ranges:"bytes"), "never bypass active Proxy")
        check(MomentMediaPolicy.mayStream(url: URL(string:"https://app.imim.chat/api/media/id")!, proxyEnabled:false, status:200, mime:"video/mp4", ranges:"bytes"), "opaque media ID can stream when server confirms video and ranges")
        check(!MomentMediaPolicy.mayStream(url: URL(string:"https://app.imim.chat/api/media/id")!, proxyEnabled:false, status:200, mime:"image/jpeg", ranges:"bytes"), "opaque image cannot be handed to video player")
        check(!MomentMediaPolicy.mayStream(url: URL(string:"https://app.imim.chat/api/media/id")!, proxyEnabled:true, status:200, mime:"video/mp4", ranges:"bytes"), "opaque stream cannot bypass Proxy")
        check(!MomentMediaPolicy.mayStream(url: url, proxyEnabled:false, status:200, mime:"video/mp4", ranges:nil), "no ranges fallback")
        check(!MomentMediaPolicy.mayStream(url: url, proxyEnabled:false, status:403, mime:"video/mp4", ranges:"bytes"), "HTTP failure fallback")
        check(MomentMediaPolicy.mayStream(url: URL(string:"https://media.example/a.m3u8")!, proxyEnabled:false, status:200, mime:"application/vnd.apple.mpegurl", ranges:nil), "HLS policy")

        let resolver = MomentMediaTypeResolver()
        check(await resolver.isVideo("/api/media/legacy-video") == nil, "network failure remains unknown instead of becoming an image")
        await ProxySession.shared.configure(200, "video/mp4")
        check(await resolver.isVideo("/api/media/legacy-video") == true, "retry after network failure can identify the same video")
        let priorCalls = await ProxySession.shared.probeCalls
        check(await resolver.isVideo("/api/media/legacy-video") == true, "successful classification is reused")
        check(await ProxySession.shared.probeCalls == priorCalls, "known video does not repeat probe")
        await ProxySession.shared.configure(200, "image/jpeg")
        check(await resolver.isVideo("/api/media/photo") == false, "confirmed image still uses image presentation")
        await ProxySession.shared.configure(503, "text/html")
        check(await resolver.isVideo("/api/media/service-error") == nil, "server failure does not become image classification")
        await ProxySession.shared.configure(200, "application/octet-stream")
        check(await resolver.isVideo("/api/media/service-error") == nil, "ambiguous binary remains retryable")
        await ProxySession.shared.configure(200, "video/mp4")
        check(await resolver.isVideo("/api/media/service-error") == true, "unknown MIME and error responses are not cached as image")

        let fast = try await MomentMediaDeadline.run(after: .seconds(1)) { 42 }
        check(fast == 42, "fast operation cancels its timeout")
        do {
            _ = try await MomentMediaDeadline.run(after: .milliseconds(10)) {
                try await Task.sleep(for: .seconds(2)); return 0
            }
            check(false, "slow operation must time out")
        } catch { check((error as? URLError)?.code == .timedOut, "deadline cancels slow transfer and reports timeout") }
        do {
            _ = try await MomentMediaDeadline.run(after: .seconds(1)) { () throws -> Int in throw URLError(.notConnectedToInternet) }
            check(false, "underlying error must propagate")
        } catch { check((error as? URLError)?.code == .notConnectedToInternet, "original network error preserved") }
        let cancelledDeadline = Task {
            try await MomentMediaDeadline.run(after: .seconds(1)) { try await Task.sleep(for: .seconds(2)); return 0 }
        }
        cancelledDeadline.cancel()
        do { _ = try await cancelledDeadline.value; check(false, "cancelled caller must stop") }
        catch { check(error is CancellationError, "caller cancellation is not converted to timeout") }

        let capacity = MomentFixtureCounter()
        let pool = MomentMediaRequests { _ in try await capacity.run(delay: .milliseconds(20)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask { _ = try await pool.fetch(URLRequest(url:URL(string:"https://fixture.example/\(index)")!), owner:"capacity") }
            }
            try await group.waitForAll()
        }
        check(await capacity.started == 40, "distinct transfers execute")
        check(await capacity.peak <= 4, "at most four active transfers")
        check(await capacity.active == 0, "no occupied permits after success")

        let dedup = MomentFixtureCounter()
        let merged = MomentMediaRequests { _ in try await dedup.run() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await merged.fetch(URLRequest(url:url), owner:"same") } }
            try await group.waitForAll()
        }
        check(await dedup.started == 1, "same owner/URL/method merged")
        async let a = merged.fetch(URLRequest(url:url), owner:"A")
        async let b = merged.fetch(URLRequest(url:url), owner:"B")
        var head = URLRequest(url:url); head.httpMethod = "HEAD"
        async let c = merged.fetch(head, owner:"A")
        _ = try await (a,b,c)
        check(await dedup.started == 4, "owners and methods do not alias")

        let cancellation = MomentFixtureCounter()
        let cancellable = MomentMediaRequests { _ in try await cancellation.run(delay: .milliseconds(300)) }
        let kept = Task { try await cancellable.fetch(URLRequest(url:url), owner:"lease") }
        try await wait { await cancellation.started == 1 }
        let removed = Task { try await cancellable.fetch(URLRequest(url:url), owner:"lease") }
        try await Task.sleep(for: .milliseconds(15))
        removed.cancel()
        _ = try await kept.value
        do { _ = try await removed.value; check(false, "cancelled consumer cannot publish") }
        catch { check(error is CancellationError, "consumer cancellation surfaced") }
        let cancellationSnapshot = await (cancellation.started, cancellation.cancelled)
        check(cancellationSnapshot == (1, 0), "one cancelled lease does not cancel another")
        let last = Task { try await cancellable.fetch(URLRequest(url:url), owner:"last") }
        try await wait { await cancellation.started == 2 }
        last.cancel()
        do { _ = try await last.value; check(false, "last consumer cancellation") } catch { check(true, "last consumer exits") }
        try await wait { await cancellation.cancelled == 1 }
        _ = try await cancellable.fetch(URLRequest(url:url), owner:"last")
        check(await cancellation.started == 3, "new lease after cancelled job starts afresh")

        let errors = MomentFixtureCounter()
        let failing = MomentMediaRequests { _ in try await errors.run(delay:.milliseconds(1), fail:true) }
        for _ in 0..<50 {
            do { _ = try await failing.fetch(URLRequest(url:url), owner:"failure"); check(false,"expected fixture failure") }
            catch { check(true,"failed job exits") }
        }
        let errorSnapshot = await (errors.started, errors.active)
        check(errorSnapshot == (50, 0), "errors release jobs and admission permits")

        let gate = MomentTransferGate(limit:1), order = MomentFixtureOrder()
        let blocker = Task { try await gate.run { await order.append(0); try await Task.sleep(for:.milliseconds(100)) } }
        try await wait { await order.values == [0] }
        let speculative = Task { try await gate.run(speculative:true) { await order.append(2) } }
        try await Task.sleep(for:.milliseconds(10))
        let visible = Task { try await gate.run { await order.append(1) } }
        let cancelledWaiter = Task { try await gate.run { await order.append(99) } }
        try await Task.sleep(for:.milliseconds(10)); cancelledWaiter.cancel()
        _ = try await (blocker.value, speculative.value, visible.value)
        do { _ = try await cancelledWaiter.value; check(false,"cancelled queued task ran") } catch { check(true,"queued cancellation") }
        check(await order.values == [0,1,2], "visible before speculative; cancelled waiter never executes")
        try await gate.run { await order.append(3) }
        check(await order.values == [0,1,2,3], "gate usable after waiter cancellation")
        print("PASS: \(checks) actual production model/policy/scheduler checks; no device/network/FPS claims")
    }
}
