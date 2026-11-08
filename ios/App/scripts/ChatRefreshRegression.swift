import Foundation

// Compile the actual refresh/cancellation methods. Fixtures replace networking,
// persistence and avatar work; no real credentials or message bodies are used.
struct Chat { var avatarCacheIdentity: String?; var avatar: String?; var type = "private" }
struct ModelContext {}
struct RemoteChat { var id: String }
struct RemoteGroup { var id: String }
@MainActor final class AuthTokenStore { static let shared = AuthTokenStore(); var token: String? = "fixture" }
@MainActor final class AvatarImageLoader {
    struct Input { var userId: String?; var urlString: String?; var isGroup = false }
    static let shared = AvatarImageLoader()
    func prefetch(_ input: [Input], allowsSourceUpdates: Bool) {}
}
@MainActor final class APIClient {
    static let shared = APIClient()
    var privateCalls = 0, groupCalls = 0
    var chats: () async throws -> [RemoteChat] = { [] }
    var groups: () async throws -> [RemoteGroup] = { [] }
    func fetchChats() async throws -> [RemoteChat] { privateCalls += 1; return try await chats() }
    func fetchGroups(userId: String) async throws -> [RemoteGroup] { groupCalls += 1; return try await groups() }
    func reset() { privateCalls = 0; groupCalls = 0; chats = { [] }; groups = { [] } }
}
@MainActor final class Model {
    var activeRefreshID: UUID?
    var isRefreshing = false
    var errorMessage: String?
    var mergedPrivate: [String] = [], mergedGroup: [String] = []
    func ensureBuiltinConversations(in chats: [Chat], modelContext: ModelContext) {}
    func merge(remoteChats: [RemoteChat], into chats: [Chat], modelContext: ModelContext) { mergedPrivate += remoteChats.map(\.id) }
    func merge(remoteGroups: [RemoteGroup], into chats: [Chat], modelContext: ModelContext) { mergedGroup += remoteGroups.map(\.id) }
// ACTUAL_REFRESH
}
@MainActor final class Gate {
    var continuation: CheckedContinuation<[RemoteChat], Error>?
    func wait() async throws -> [RemoteChat] { try await withCheckedThrowingContinuation { continuation = $0 } }
    func ready() async { for _ in 0..<10000 { if continuation != nil { return }; await Task.yield() }; fatalError("gate never entered") }
    func finish(_ result: Result<[RemoteChat], Error>) { let c = continuation; continuation = nil; c?.resume(with: result) }
}
@main struct Regression {
    @MainActor static func main() async {
        let defaults = UserDefaults.standard
        let oldOwner = defaults.object(forKey: "current_user_id")
        defer {
            if let oldOwner { defaults.set(oldOwner, forKey: "current_user_id") }
            else { defaults.removeObject(forKey: "current_user_id") }
        }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label); checks += 1 }
        let api = APIClient.shared
        func fresh() -> Model {
            api.reset(); AuthTokenStore.shared.token = "fixture"
            defaults.set("fixture-owner", forKey: "current_user_id")
            return Model()
        }
        func refresh(_ model: Model) async { await model.refresh(chats: [], modelContext: ModelContext()) }
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let model = fresh(); api.chats = { throw error }
            await refresh(model)
            expect(model.errorMessage == nil, "private cancellation is silent")
            expect(api.groupCalls == 0, "private cancellation stops group request")
            expect(!model.isRefreshing, "private cancellation clears spinner")
        }
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let model = fresh(); api.chats = { [.init(id: "valid")] }; api.groups = { throw error }
            await refresh(model)
            expect(model.errorMessage == nil, "group cancellation is silent")
            expect(model.mergedPrivate == ["valid"] && !model.isRefreshing, "private merge survives group cancellation")
        }
        do {
            let model = fresh()
            api.chats = { throw NSError(domain: "kCFErrorDomainCFNetwork", code: 310) }
            api.groups = { throw URLError(.timedOut) }
            await refresh(model)
            expect(model.errorMessage?.contains("私聊：") == true && model.errorMessage?.contains("群聊：") == true, "real errors remain visible")
            expect(api.groupCalls == 1 && !model.isRefreshing, "real private failure still allows groups")
            api.chats = { [.init(id: "new")] }; api.groups = { [.init(id: "group")] }
            await refresh(model)
            expect(model.errorMessage == nil && model.mergedPrivate == ["new"] && model.mergedGroup == ["group"], "retry clears error and merges")
        }
        do {
            let model = fresh(), gate = Gate(); api.chats = { try await gate.wait() }
            let task = Task { await refresh(model) }; await gate.ready(); task.cancel()
            gate.finish(.success([.init(id: "cancelled")]))
            await task.value
            expect(model.mergedPrivate.isEmpty && api.groupCalls == 0, "cancelled task cannot merge late success")
            expect(model.errorMessage == nil && !model.isRefreshing, "cancelled task UI resets silently")
        }
        do {
            let model = fresh(), old = Gate(), newest = Gate()
            api.chats = { try await old.wait() }
            let first = Task { await refresh(model) }; await old.ready()
            api.chats = { try await newest.wait() }
            let second = Task { await refresh(model) }; await newest.ready()
            old.finish(.failure(URLError(.timedOut))); await first.value
            expect(model.errorMessage == nil && model.isRefreshing, "old failure cannot alter newest spinner/error")
            newest.finish(.success([.init(id: "latest")]))
            await second.value
            expect(model.mergedPrivate == ["latest"] && api.groupCalls == 1 && !model.isRefreshing, "latest refresh owns results")
        }
        for changeToken in [false, true] {
            let model = fresh(), gate = Gate(); api.chats = { try await gate.wait() }
            let task = Task { await refresh(model) }; await gate.ready()
            if changeToken { AuthTokenStore.shared.token = "replacement" }
            else { defaults.set("other-owner", forKey: "current_user_id") }
            gate.finish(.success([.init(id: "wrong-owner")]))
            await task.value
            expect(model.mergedPrivate.isEmpty && api.groupCalls == 0 && model.errorMessage == nil, "account/token change rejects old merge")
        }
        do {
            let model = fresh(); AuthTokenStore.shared.token = nil; model.errorMessage = "previous"
            await refresh(model)
            expect(api.privateCalls == 0 && api.groupCalls == 0 && model.errorMessage == nil && !model.isRefreshing, "signed-out refresh is local only")
        }
        print("PASS: \(checks) actual refresh cancellation, ownership, retry and error checks (isolated fixtures; not device proof)")
    }
}
