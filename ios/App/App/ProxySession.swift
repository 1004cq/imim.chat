import Foundation
import Combine
import Security
import Network
import Darwin

struct ProxyConfig: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var host: String
    var port: Int
    // Hydrated from Keychain; intentionally omitted from the disk metadata.
    var username = ""
    var enabled = false
    var latencyMs: Int?
    var lastStatus: Status = .idle
    var requiresAuthentication = false
    enum Status: String, Codable, Sendable { case idle, checking, connected, failed }
    enum CodingKeys: String, CodingKey {
        case id, title, host, port, enabled, latencyMs, lastStatus, requiresAuthentication
    }

    func validated() throws -> Self {
        var copy = self
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.host.isEmpty, copy.host.utf8.count <= 253, copy.title.count <= 120,
              copy.host.rangeOfCharacter(from: .controlCharacters) == nil,
              !copy.host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !copy.host.contains(where: { "/?#@%\\".contains($0) }),
              (1...65535).contains(port), username.utf8.count <= 255 else {
            throw ProxyError.invalidConfig
        }
        if copy.host.hasPrefix("["), copy.host.hasSuffix("]") {
            copy.host = String(copy.host.dropFirst().dropLast())
        }
        if copy.host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, copy.host, &address) == 1 else { throw ProxyError.invalidConfig }
        }
        if copy.title.isEmpty { copy.title = "\(copy.host):\(port)" }
        return copy
    }
}

enum ProxyError: LocalizedError {
    case invalidConfig, credentialsUnavailable, storageFailure, invalidLink
    var errorDescription: String? {
        switch self {
        case .invalidConfig: return ProxyCopy.text("请输入有效的服务器和端口（1–65535）", "Enter a valid server and port (1–65535).")
        case .credentialsUnavailable: return ProxyCopy.text("无法读取代理凭据，请重新填写或关闭代理", "Proxy credentials are unavailable. Re-enter them or turn Proxy off.")
        case .storageFailure: return ProxyCopy.text("无法保存代理配置", "Unable to save Proxy settings.")
        case .invalidLink: return ProxyCopy.text("代理链接格式不正确", "Invalid Proxy link.")
        }
    }
}

struct ProxyCredentials: Codable, Equatable, Sendable {
    var username: String
    var password: String
}

protocol ProxyCredentialStorage {
    func read(id: UUID) throws -> ProxyCredentials?
    func write(_ credentials: ProxyCredentials, id: UUID) throws
    func delete(id: UUID) throws
}

struct ProxyKeychain: ProxyCredentialStorage {
    var service = "chat.imim.proxy.credentials"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "proxy-\(id.uuidString)",
         kSecAttrSynchronizable as String: false]
    }
    func read(id: UUID) throws -> ProxyCredentials? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let result = try? JSONDecoder().decode(ProxyCredentials.self, from: data) else {
            throw ProxyError.credentialsUnavailable
        }
        return result
    }
    func write(_ credentials: ProxyCredentials, id: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id)
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ProxyError.storageFailure }
        } else if status != errSecSuccess { throw ProxyError.storageFailure }
    }
    func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProxyError.storageFailure }
    }
}

struct ProxyRepository {
    static let preferenceKey = "app_socks5_proxies_v1"
    var defaults: UserDefaults = .standard
    var keychain: any ProxyCredentialStorage = ProxyKeychain()
    func load() -> [ProxyConfig] {
        guard let data = defaults.data(forKey: Self.preferenceKey),
              let stored = try? JSONDecoder().decode([ProxyConfig].self, from: data) else { return [] }
        var seen = Set<UUID>(), enabled = false
        return stored.compactMap { entry in
            guard seen.insert(entry.id).inserted, var item = try? entry.validated() else { return nil }
            if item.enabled {
                item.enabled = !enabled
                enabled = true
                item.lastStatus = .idle
                item.latencyMs = nil
            }
            if item.lastStatus == .checking { item.lastStatus = .idle; item.latencyMs = nil }
            item.username = (try? keychain.read(id: item.id))?.username ?? ""
            return item
        }
    }
    func save(_ list: [ProxyConfig]) throws {
        guard list.filter(\.enabled).count <= 1 else { throw ProxyError.invalidConfig }
        defaults.set(try JSONEncoder().encode(list), forKey: Self.preferenceKey)
    }
    func bootstrap() -> ProxyBootstrap {
        let active = load().first(where: \.enabled)
        do { return .init(config: active, credentials: try active.flatMap { try keychain.read(id: $0.id) }, blocked: false) }
        catch { return .init(config: active, credentials: nil, blocked: true) }
    }
}

struct ProxyBootstrap: Sendable {
    let config: ProxyConfig?
    let credentials: ProxyCredentials?
    let blocked: Bool
}

struct ProxyImport: Identifiable, Sendable {
    let id = UUID()
    let config: ProxyConfig
    let password: String // Transient until explicit confirmation; never logged.
    /// Routing only; parsing still validates every parameter before presentation.
    static func isCandidate(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let scheme = c.scheme?.lowercased(), host = c.host?.lowercased()
        if scheme == "imim" { return host == "proxy" }
        if scheme == "tg" { return host == "socks" }
        guard scheme == "https" else { return false }
        return (host == "app.imim.chat" && c.path == "/proxy")
            || (["t.me", "telegram.me", "telegram.dog"].contains(host ?? "") && c.path == "/socks")
    }
    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 8192, isCandidate(url),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.user == nil, c.password == nil, c.fragment == nil, c.port == nil,
              c.scheme?.lowercased() == "https" || c.path.isEmpty || c.path == "/" else {
            throw ProxyError.invalidLink
        }
        let items = c.queryItems ?? []
        var values: [String: String] = [:]
        for item in items {
            guard ["server", "port", "user", "pass", "name"].contains(item.name),
                  values[item.name] == nil, let value = item.value else { throw ProxyError.invalidLink }
            values[item.name] = value
        }
        guard let host = values["server"], let portText = values["port"],
              !portText.isEmpty, portText.allSatisfy(\.isNumber), let port = Int(portText) else { throw ProxyError.invalidLink }
        let username = values["user"] ?? "", password = values["pass"] ?? ""
        guard password.utf8.count <= 255, !username.isEmpty || password.isEmpty else { throw ProxyError.invalidLink }
        let config = try ProxyConfig(title: values["name"] ?? "", host: host, port: port,
            username: username, requiresAuthentication: !username.isEmpty).validated()
        return Self(config: config, password: password)
    }
}

/// Link styling never interprets message Markdown or fetches a remote preview.
enum ProxyMessageLinks {
    private static let expression = try? NSRegularExpression(pattern: #"(?i)(?:https://|imim://|tg://)[^\s<>\"]+"#)
    static func attributed(_ text: String) -> AttributedString {
        guard text.utf8.count <= 65536, let expression else { return AttributedString(text) }
        var result = AttributedString(), cursor = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
                  ProxyImport.isCandidate(url), url.absoluteString.utf8.count <= 8192 else { continue }
            result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.user = nil
            components?.password = nil
            let redactedItems = components?.queryItems?.map {
                $0.name == "pass" ? URLQueryItem(name: "pass", value: "********") : $0
            }
            components?.queryItems = redactedItems
            var link = AttributedString(components?.string ?? "Proxy")
            link.link = url
            result.append(link)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(text[cursor...])))
        return result
    }
}

/// One mutable transport owner. A configuration change cancels old tasks;
/// callers get the new session without restarting. Authentication failure
/// never silently falls back to direct networking.
actor ProxySession {
    static let shared = ProxySession(snapshot: ProxyRepository().bootstrap())
    private var session: URLSession
    private var blocked = false
    private var requests: [UUID: URLSessionTask] = [:]

    init(snapshot: ProxyBootstrap) {
        do {
            guard !snapshot.blocked else { throw ProxyError.credentialsUnavailable }
            session = try Self.makeSession(config: snapshot.config, credentials: snapshot.credentials)
        } catch {
            session = URLSession(configuration: .ephemeral)
            blocked = true
        }
    }

    private func current() throws -> URLSession {
        guard !blocked else { throw ProxyError.credentialsUnavailable }
        return session
    }

    func data(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        try await perform(request, upload: nil, delegate: delegate)
    }

    func upload(for request: URLRequest, from data: Data) async throws -> (Data, URLResponse) {
        try await perform(request, upload: data, delegate: nil)
    }

    func webSocketTask(with url: URL) throws -> URLSessionWebSocketTask {
        // Create synchronously under the same actor as replacement. Returning
        // an already-created task is safe even if the old session is cancelled.
        try current().webSocketTask(with: url)
    }

    #if PROXY_REGRESSION_TESTS
    func sessionIdentifier() -> ObjectIdentifier { ObjectIdentifier(session) }
    func isDirect() -> Bool { session.configuration.proxyConfigurations.isEmpty }
    #endif

    private func perform(_ request: URLRequest, upload: Data?, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let session = try current()
                    let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { [weak self] data, response, error in
                        Task { await self?.finished(id) }
                        if let error { continuation.resume(throwing: error) }
                        else if let response { continuation.resume(returning: (data ?? Data(), response)) }
                        else { continuation.resume(throwing: URLError(.badServerResponse)) }
                    }
                    let task: URLSessionTask
                    if let upload { task = session.uploadTask(with: request, from: upload, completionHandler: completion) }
                    else { task = session.dataTask(with: request, completionHandler: completion) }
                    task.delegate = delegate
                    requests[id] = task
                    task.resume()
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func finished(_ id: UUID) { requests[id] = nil }
    private func cancel(_ id: UUID) { requests[id]?.cancel() }

    func replace(config: ProxyConfig?, credentials: ProxyCredentials?) throws {
        let replacement = try Self.makeSession(config: config, credentials: credentials)
        let previous = session
        session = replacement
        blocked = false
        previous.invalidateAndCancel()
    }

    nonisolated static func makeSession(config: ProxyConfig?, credentials: ProxyCredentials?) throws -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        if let config = try config?.validated() {
            if config.requiresAuthentication, credentials?.username.isEmpty != false { throw ProxyError.credentialsUnavailable }
            var dictionary: [AnyHashable: Any] = ["SOCKSEnable": 1, "SOCKSProxy": config.host, "SOCKSPort": config.port]
            var native = Network.ProxyConfiguration(socksv5Proxy: .hostPort(
                host: .init(config.host), port: .init(rawValue: UInt16(config.port))!))
            native.allowFailover = false
            if let credentials, !credentials.username.isEmpty {
                dictionary["SOCKSUser"] = credentials.username
                dictionary["SOCKSPassword"] = credentials.password
                native.applyCredential(username: credentials.username, password: credentials.password)
            }
            configuration.connectionProxyDictionary = dictionary
            // iOS 17+ native transport also covers URLSessionWebSocketTask.
            // This is Network's session configuration, NOT a system extension.
            configuration.proxyConfigurations = [native]
        } else { configuration.proxyConfigurations = [] }
        return URLSession(configuration: configuration)
    }

    /// Explicit preview test. Does not save credentials or replace the active transport.
    nonisolated static func previewLatency(_ imported: ProxyImport) async throws -> Int {
        try Task.checkCancellation()
        let session = try makeSession(config: imported.config, credentials: .init(
            username: imported.config.username, password: imported.password))
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://app.imim.chat/api/health")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        let started = CFAbsoluteTimeGetCurrent()
        let (_, response) = try await session.data(for: request, delegate: ProxyHealthDelegate())
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()
        return max(0, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
    }
}

private final class ProxyHealthDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // A health test never follows an external redirect.
    }
}

@MainActor
final class ProxyStore: ObservableObject {
    static let shared = ProxyStore()
    @Published private(set) var configs: [ProxyConfig]
    @Published private(set) var isChanging = false
    @Published var errorMessage: String?
    private let repository: ProxyRepository
    private let transport: ProxySession
    private var tests: [UUID: UUID] = [:]
    private var didTestOnLaunch = false
    var active: ProxyConfig? { configs.first(where: \.enabled) }

    init(repository: ProxyRepository = ProxyRepository(), transport: ProxySession = .shared) {
        self.repository = repository
        self.transport = transport
        configs = repository.load()
    }
    func add(_ config: ProxyConfig, password: String) throws -> UUID {
        guard !isChanging else { throw ProxyError.storageFailure }
        var item = try config.validated()
        guard password.utf8.count <= 255, !item.username.isEmpty || password.isEmpty else { throw ProxyError.invalidConfig }
        item.enabled = false
        item.requiresAuthentication = !item.username.isEmpty
        item.lastStatus = .idle
        item.latencyMs = nil
        guard !configs.contains(where: { $0.id == item.id }) else { throw ProxyError.invalidConfig }
        try repository.keychain.write(.init(username: item.username, password: password), id: item.id)
        do { try repository.save(configs + [item]) }
        catch { try? repository.keychain.delete(id: item.id); throw error }
        configs.append(item)
        return item.id
    }
    /// Called only by the preview's explicit Connect button. Reuse an identical
    /// saved endpoint/credential pair without overwriting a different entry.
    func connect(_ imported: ProxyImport) async throws -> UUID {
        guard !isChanging else { throw ProxyError.storageFailure }
        let config = try imported.config.validated()
        var existingID: UUID?
        for saved in configs where saved.host == config.host && saved.port == config.port && saved.username == config.username {
            if try repository.keychain.read(id: saved.id) == ProxyCredentials(username: config.username, password: imported.password) {
                existingID = saved.id
                break
            }
        }
        let id = try existingID ?? add(config, password: imported.password)
        await enable(id)
        guard active?.id == id else { throw ProxyError.storageFailure }
        return id
    }
    func enable(_ id: UUID?) async {
        guard !isChanging, id == nil || configs.contains(where: { $0.id == id }) else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            var next = configs
            for i in next.indices {
                next[i].enabled = next[i].id == id
                if next[i].enabled { next[i].lastStatus = .checking; next[i].latencyMs = nil }
                else if next[i].lastStatus == .checking { next[i].lastStatus = .idle; next[i].latencyMs = nil }
            }
            let selected = next.first(where: \.enabled)
            let credentials = try selected.flatMap { try repository.keychain.read(id: $0.id) }
            // Validate before changing saved state or the transport.
            if let selected, selected.requiresAuthentication, credentials?.username.isEmpty != false {
                throw ProxyError.credentialsUnavailable
            }
            try repository.save(next)
            try await transport.replace(config: selected, credentials: credentials)
            tests.removeAll()
            configs = next
            errorMessage = nil
            NotificationCenter.default.post(name: .imimProxySessionDidChange, object: nil)
            if let id { Task { await self.measure(id) } }
        } catch { errorMessage = error.localizedDescription }
    }
    func delete(_ id: UUID) async {
        guard !isChanging else { return }
        if active?.id == id { await enable(nil) }
        guard active?.id != id else { return }
        do {
            try repository.keychain.delete(id: id)
            let next = configs.filter { $0.id != id }
            try repository.save(next)
            tests[id] = nil
            configs = next
        } catch { errorMessage = error.localizedDescription }
    }
    func testOnLaunch() {
        guard !didTestOnLaunch else { return }
        didTestOnLaunch = true
        if let active { Task { await self.measure(active.id) } }
    }
    func measure(_ id: UUID) async {
        guard let index = configs.firstIndex(where: { $0.id == id }), tests[id] == nil else { return }
        let config = configs[index], ticket = UUID()
        tests[id] = ticket
        configs[index].lastStatus = .checking
        configs[index].latencyMs = nil
        var temporary: URLSession?
        defer { temporary?.invalidateAndCancel(); if tests[id] == ticket { tests[id] = nil } }
        do {
            var request = URLRequest(url: URL(string: "https://app.imim.chat/api/health")!,
                cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.httpMethod = "GET"
            let started = CFAbsoluteTimeGetCurrent()
            let response: URLResponse
            if config.enabled {
                (_, response) = try await transport.data(for: request, delegate: ProxyHealthDelegate())
            } else {
                let session = try ProxySession.makeSession(config: config, credentials: repository.keychain.read(id: id))
                temporary = session
                (_, response) = try await session.data(for: request, delegate: ProxyHealthDelegate())
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            try Task.checkCancellation()
            guard tests[id] == ticket, let i = configs.firstIndex(where: { $0.id == id }) else { return }
            configs[i].lastStatus = .connected
            configs[i].latencyMs = max(0, Int((CFAbsoluteTimeGetCurrent() - started) * 1000))
        } catch {
            guard tests[id] == ticket, let i = configs.firstIndex(where: { $0.id == id }) else { return }
            configs[i].lastStatus = .failed
            configs[i].latencyMs = nil
        }
        try? repository.save(configs)
    }
}

extension Notification.Name {
    static let imimProxySessionDidChange = Notification.Name("IMIMProxySessionDidChange")
}
