
// Actual model above; network and values below are deterministic fixtures.
// Does not read App defaults, send requests, or touch user storage.
struct MomentFeedItem: Identifiable, Sendable {
    let id: String
    var content = "fixture"
    var isLiked = false
    var likeCount = 0
    var authorId = "author"
    var authorAvatar: String? = nil
    func updated(isLiked: Bool, likeCount: Int) -> Self {
        var next = self; next.isLiked = isLiked; next.likeCount = likeCount; return next
    }
}
struct MomentFeedResponse: Sendable {
    let moments: [MomentFeedItem]
    var nextCursor: String? = nil
    var hasMore: Bool? = false
}
struct MomentLikeResponse: Sendable { let liked: Bool; let likeCount: Int }
struct MomentCreateMedia: Sendable {}
struct MomentUploadSelection { let data: Data; let fileName: String; let mimeType: String; let type: String }
enum MomentComposerError: Error { case emptyContent }
@MainActor enum MomentImagePipeline {
    static var owner = "A"
    static func prefetch(_ items: [MomentFeedItem]) {}
}
@MainActor final class AvatarImageLoader {
    struct Source { let userId: String; let urlString: String? }
    static let shared = AvatarImageLoader()
    func prefetch(_ sources: [Source], allowsSourceUpdates: Bool) {}
}
func momentAvatarSource(_ value: String?) -> String? { value }
actor APIClient {
    static let shared = APIClient()
    private(set) var likes = 0
    private(set) var comments = 0
    private(set) var feeds = 0
    private(set) var uploads = 0
    private(set) var creates = 0
    private(set) var publishedContent: String?
    private var uploadRequests: [Int: CheckedContinuation<MomentCreateMedia, Error>] = [:]
    private var createRequests: [Int: CheckedContinuation<Void, Error>] = [:]
    private var likeRequests: [Int: CheckedContinuation<MomentLikeResponse, Error>] = [:]
    private var commentRequests: [Int: CheckedContinuation<Void, Error>] = [:]
    private var feedRequests: [Int: CheckedContinuation<MomentFeedResponse, Error>] = [:]
    func toggleMomentLike(momentId: String) async throws -> MomentLikeResponse {
        likes += 1; let id = likes
        return try await withCheckedThrowingContinuation { likeRequests[id] = $0 }
    }
    func createMomentComment(momentId: String, content: String) async throws {
        comments += 1; let id = comments
        try await withCheckedThrowingContinuation { commentRequests[id] = $0 }
    }
    func fetchMomentsFeed(cursor: String? = nil) async throws -> MomentFeedResponse {
        feeds += 1; let id = feeds
        return try await withCheckedThrowingContinuation { feedRequests[id] = $0 }
    }
    func completeLike(_ id: Int, liked: Bool = true, count: Int = 8) {
        likeRequests.removeValue(forKey: id)!.resume(returning: .init(liked: liked, likeCount: count))
    }
    func failLike(_ id: Int) { likeRequests.removeValue(forKey: id)!.resume(throwing: URLError(.timedOut)) }
    func completeComment(_ id: Int, fail: Bool = false) {
        let request = commentRequests.removeValue(forKey: id)!
        if fail { request.resume(throwing: URLError(.timedOut)) }
        else { request.resume(returning: ()) }
    }
    func completeFeed(_ id: Int, content: String = "fixture", liked: Bool = false, count: Int = 0) {
        feedRequests.removeValue(forKey: id)!.resume(returning: .init(moments: [
            .init(id: "post", content: content, isLiked: liked, likeCount: count)
        ]))
    }
    func failFeed(_ id: Int, error: any Error) { feedRequests.removeValue(forKey: id)!.resume(throwing: error) }
    func uploadMomentMedia(data: Data, fileName: String, mimeType: String, type: String) async throws -> MomentCreateMedia {
        uploads += 1; let id = uploads
        return try await withCheckedThrowingContinuation { uploadRequests[id] = $0 }
    }
    func createMoment(content: String, media: [MomentCreateMedia]) async throws {
        creates += 1; let id = creates; publishedContent = content
        try await withCheckedThrowingContinuation { createRequests[id] = $0 }
    }
    func completeUpload(_ id: Int) { uploadRequests.removeValue(forKey: id)!.resume(returning: .init()) }
    func completeCreate(_ id: Int) { createRequests.removeValue(forKey: id)!.resume(returning: ()) }
    func publicationCounts() -> (uploads: Int, creates: Int) { (uploads, creates) }
}
@main @MainActor struct MomentsInteractionRegression {
    static var checks = 0
    static func check(_ result: Bool, _ note: String) {
        guard result else { fatalError("FAIL: \(note)") }; checks += 1
    }
    static func until(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        fatalError("Timed out waiting for fixture")
    }
    private static func refresh(_ model: MomentsFeedViewModel, id: Int, content: String = "fixture") async throws {
        let request = Task { await model.refresh() }
        try await until { await APIClient.shared.feeds == id }
        await APIClient.shared.completeFeed(id, content: content)
        await request.value
    }
    static func main() async throws {
        let model = MomentsFeedViewModel()
        try await refresh(model, id: 1)
        model.toggleLike("post")
        model.toggleLike("post")
        check(model.moments[0].isLiked && model.moments[0].likeCount == 1, "one immediate optimistic update")
        try await until { await APIClient.shared.likes == 1 }
        await APIClient.shared.completeLike(1)
        try await until { model.likingMomentIDs.isEmpty }
        check(await APIClient.shared.likes == 1, "rapid taps send only one toggle")
        check(model.moments[0].isLiked && model.moments[0].likeCount == 8, "server like result reconciles")
        model.toggleLike("post")
        try await until { await APIClient.shared.likes == 2 }
        await APIClient.shared.failLike(2)
        try await until { model.likingMomentIDs.isEmpty }
        check(model.moments[0].isLiked && model.moments[0].likeCount == 8, "failure rolls back like fields")
        check(model.errorMessage != nil, "failure remains observable")

        model.toggleLike("post")
        try await until { await APIClient.shared.likes == 3 }
        try await refresh(model, id: 2, content: "new comments")
        await APIClient.shared.completeLike(3)
        try await until { model.likingMomentIDs.isEmpty }
        check(model.moments[0].content == "new comments" && !model.moments[0].isLiked, "late success cannot replace refreshed content")
        model.toggleLike("post")
        try await until { await APIClient.shared.likes == 4 }
        try await refresh(model, id: 3, content: "newer comments")
        await APIClient.shared.failLike(4)
        try await until { model.likingMomentIDs.isEmpty }
        check(model.moments[0].content == "newer comments" && model.errorMessage == nil, "late failure cannot roll back refreshed feed")

        model.toggleLike("post")
        try await until { await APIClient.shared.likes == 5 }
        MomentImagePipeline.owner = "B"
        await APIClient.shared.completeLike(5)
        try await until { model.likingMomentIDs.isEmpty }
        check(model.moments[0].likeCount == 1, "old owner response cannot reconcile into new account")
        try await refresh(model, id: 4)
        model.toggleLike("post")
        MomentImagePipeline.owner = "C"
        try await until { model.likingMomentIDs.isEmpty }
        check(await APIClient.shared.likes == 5, "account change before task starts prevents network mutation")

        let oldComment = Task { try await model.comment(on: "post", content: "hello") }
        try await until { await APIClient.shared.comments == 1 }
        MomentImagePipeline.owner = "D"
        await APIClient.shared.completeComment(1)
        do { try await oldComment.value; check(false, "old comment must cancel") }
        catch { check(error is CancellationError, "old comment does not refresh another account") }
        check(await APIClient.shared.feeds == 4, "account change causes no background feed request")
        let failedComment = Task { try await model.comment(on: "post", content: "retry me") }
        try await until { await APIClient.shared.comments == 2 }
        await APIClient.shared.completeComment(2, fail: true)
        do { try await failedComment.value; check(false, "comment error must propagate") }
        catch { check((error as? URLError)?.code == .timedOut, "comment failure reaches composer instead of being swallowed") }
        let validComment = Task { try await model.comment(on: "post", content: "hello") }
        try await until { await APIClient.shared.comments == 3 }
        await APIClient.shared.completeComment(3)
        try await until { await APIClient.shared.feeds == 5 }
        await APIClient.shared.completeFeed(5, content: "comment visible")
        try await validComment.value
        check(model.moments[0].content == "comment visible", "successful comment refreshes current feed")

        let item = MomentUploadSelection(data: Data([1]), fileName: "fixture.jpg", mimeType: "image/jpeg", type: "image")
        var oldFinished = false
        let oldPublish = Task { defer { oldFinished = true }; try await model.publish(content: "draft", media: [item, item]) }
        try await until { await APIClient.shared.uploads == 1 }
        MomentImagePipeline.owner = "E"
        await APIClient.shared.completeUpload(1)
        try await until {
            let counts = await APIClient.shared.publicationCounts()
            return oldFinished || counts.uploads > 1
        }
        let oldCounts = await APIClient.shared.publicationCounts()
        check(oldCounts.uploads == 1 && oldCounts.creates == 0, "no second upload or publication after account change")
        do { try await oldPublish.value; check(false, "old publisher must cancel") }
        catch { check(error is CancellationError, "account change during upload cancels publication") }
        check(await APIClient.shared.feeds == 5, "old publisher cannot refresh new account")

        let cancelledPublish = Task { try await model.publish(content: "draft", media: [item, item]) }
        try await until { await APIClient.shared.uploads == 2 }
        cancelledPublish.cancel()
        await APIClient.shared.completeUpload(2)
        do { try await cancelledPublish.value; check(false, "cancelled publisher must stop") }
        catch { check(error is CancellationError, "cancelled transport late success cannot resume publication") }
        let cancelledCounts = await APIClient.shared.publicationCounts()
        check(cancelledCounts.uploads == 2 && cancelledCounts.creates == 0, "cancelled publisher stops remaining requests")

        let duringCreate = Task { try await model.publish(content: "draft") }
        try await until { await APIClient.shared.creates == 1 }
        MomentImagePipeline.owner = "F"
        await APIClient.shared.completeCreate(1)
        do { try await duringCreate.value; check(false, "old create response must stop") }
        catch { check(error is CancellationError, "account change after submitted create rejects follow-up") }
        check(await APIClient.shared.feeds == 5, "already submitted create does not refresh another account")

        let validPublish = Task { try await model.publish(content: "  hello  ", media: [item]) }
        try await until { await APIClient.shared.uploads == 3 }
        await APIClient.shared.completeUpload(3)
        try await until { await APIClient.shared.creates == 2 }
        check(await APIClient.shared.publishedContent == "hello", "successful publication preserves normalized content")
        await APIClient.shared.completeCreate(2)
        try await until { await APIClient.shared.feeds == 6 }
        await APIClient.shared.completeFeed(6, content: "published")
        try await validPublish.value
        check(model.moments[0].content == "published", "successful publication refreshes same owner")

        for error in [CancellationError() as any Error, URLError(.cancelled) as any Error] {
            let count = await APIClient.shared.feeds + 1
            let refresh = Task { await model.refresh() }
            try await until { await APIClient.shared.feeds == count }
            await APIClient.shared.failFeed(count, error: error)
            await refresh.value
            check(model.errorMessage == nil && !model.isLoading, "transport cancellation is silent and clears loading")
        }
        print("PASS: \(checks) actual model interaction checks; fixture network, not device taps")
    }
}
