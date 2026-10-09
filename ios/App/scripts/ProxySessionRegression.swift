import Foundation
import Combine

// No App preferences, accounts, production API tokens or owner proxy data.
enum ProxyCopy { static func text(_ chinese: String, _ english: String) -> String { english } }
final class FixtureVault: ProxyCredentialStorage {
    var entries: [UUID: ProxyCredentials] = [:]
    func read(id: UUID) throws -> ProxyCredentials? { entries[id] }
    func write(_ credentials: ProxyCredentials, id: UUID) throws { entries[id] = credentials }
    func delete(id: UUID) throws { entries[id] = nil }
}
actor OpenEvents {
    var count = 0
    func opened() { count += 1 }
}
final class FixtureWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    let events = OpenEvents()
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { await events.opened() }
    }
}

@main @MainActor
struct ProxyRegression {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        if !value { FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8)) }
        precondition(value, message)
        checks += 1
        FileHandle.standardError.write(Data("CHECK \(checks): \(message)\n".utf8))
    }
    static func rejected(_ link: String) {
        do { _ = try ProxyImport.parse(URL(string: link)!); check(false, "link must reject") }
        catch { check(true, "rejected invalid link") }
    }
    static func main() async throws {
        let ports = CommandLine.arguments.dropFirst().compactMap(Int.init)
        let httpPort = ports[0], proxyPort = ports[1], closedPort = ports[2]
        let fixtureURL = URL(string: "http://127.0.0.1:\(httpPort)/api/health")!
        let proxyTarget = URL(string: "http://imim-proxy-fixture.invalid:\(httpPort)/api/health")!
        let importValue = try ProxyImport.parse(URL(string: "imim://proxy?server=127.0.0.1&port=1080&user=fixture-user&pass=fixture-pass&name=Fixture")!)
        check(importValue.config.host == "127.0.0.1" && importValue.config.port == 1080, "custom scheme parser")
        check(importValue.password == "fixture-pass" && !importValue.config.enabled, "import remains transient/disabled")
        let web = try ProxyImport.parse(URL(string: "https://app.imim.chat/proxy?server=example.test&port=65535")!)
        check(web.config.port == 65535, "own HTTPS link")
        for prefix in ["https://t.me/socks", "https://telegram.me/socks", "https://telegram.dog/socks", "tg://socks", "https://T.ME/socks"] {
            let value = try ProxyImport.parse(URL(string: prefix + "?server=example.test&port=1080&user=fixture-user&pass=fixture%2Bpass%26secret")!)
            check(value.config.host == "example.test" && value.password == "fixture+pass&secret" && !value.config.enabled, "SOCKS link variants decode transient credentials")
        }
        for link in ["https://t.me/proxy?server=a&port=1&secret=x", "tg://proxy?server=a&port=1&secret=x", "https://t.me.evil.test/socks?server=a&port=1", "https://t.me:443/socks?server=a&port=1", "https://fixture-user@t.me/socks?server=a&port=1", "https://t.me/socks?server=a&port=1&pass=x", "https://t.me/socks?server=a&port=1&user=x&pass=y&pass=z", "https://t.me/socks?server=a&port=1#fragment", "tg://socks/extra?server=a&port=1"] { rejected(link) }
        let socksLink = "https://t.me/socks?server=example.test&port=1080&user=fixture-user&pass=fixture-secret"
        let messageText = "Literal **text** and \(socksLink) then imim://proxy?server=second.test&port=1081"
        let styled = ProxyMessageLinks.attributed(messageText)
        let displayed = String(styled.characters)
        check(displayed.hasPrefix("Literal **text** and "), "message Markdown stays literal")
        check(!displayed.contains("fixture-secret") && displayed.contains("pass=********"), "display hides link password")
        check(styled.runs.compactMap(\.link).count == 2, "multiple proxy links are clickable")
        check(styled.runs.compactMap(\.link).first?.absoluteString == socksLink, "tap retains exact transient payload")
        check(ProxyMessageLinks.attributed("https://example.test/x").runs.compactMap(\.link).isEmpty, "unrelated links are not hijacked")
        check(ProxyMessageLinks.attributed(String(repeating: "x", count: 65537)).runs.compactMap(\.link).isEmpty, "long message parsing is bounded")
        check(!ProxyImport.isCandidate(URL(string: "https://app.imim.chat/api/health")!), "ordinary app URL is not imported")
        rejected("https://t.me/socks?server=a&port=1&name=" + String(repeating: "x", count: 8192))
        let ipv6 = try ProxyImport.parse(URL(string: "imim://proxy?server=%5B%3A%3A1%5D&port=1080")!)
        check(ipv6.config.host == "::1", "IPv6 normalization")
        for link in ["imim://proxy?server=a&port=0", "imim://proxy?server=a&port=65536", "imim://proxy?server=a&port=abc", "imim://proxy?server=a&port=1&port=2", "imim://proxy?server=a%2Fb&port=1", "imim://proxy?server=a&port=1&pass=x", "imim://proxy?server=a&port=1&extra=x", "https://evil.test/proxy?server=a&port=1", "http://app.imim.chat/proxy?server=a&port=1", "https://wed.imim.chat/proxy?server=a&port=1", "imim://proxy?server=a&port=1#secret", "imim://wrong?server=a&port=1", "imim://proxy?server=host%3A80&port=1"] { rejected(link) }
        let suite = "imim-proxy-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = FixtureVault()
        let repository = ProxyRepository(defaults: defaults, keychain: vault)
        let transport = ProxySession(snapshot: repository.bootstrap())
        let store = ProxyStore(repository: repository, transport: transport)
        check(store.configs.isEmpty, "isolated empty preferences")
        let preview = try ProxyImport.parse(URL(string: "https://t.me/socks?server=127.0.0.1&port=\(proxyPort)&user=fixture-user&pass=fixture-pass")!)
        let beforePreview = await transport.sessionIdentifier()
        do { _ = try await ProxySession.previewLatency(preview); check(false, "fixture rejects own production destination") }
        catch { check(true, "preview failure is bounded and fail-closed") }
        check(store.configs.isEmpty && vault.entries.isEmpty && defaults.data(forKey: ProxyRepository.preferenceKey) == nil, "preview does not save metadata or credentials")
        check(await transport.sessionIdentifier() == beforePreview && store.active == nil, "preview does not switch the active transport")
        let cancelledProbe = Task { try await ProxySession.previewLatency(preview) }
        cancelledProbe.cancel()
        do { _ = try await cancelledProbe.value; check(false, "cancelled probe must not succeed") }
        catch { check(true, "cancelled preview probe returns without publishing success") }
        var config = ProxyConfig(title: "Fixture", host: "127.0.0.1", port: proxyPort, username: "fixture-user")
        let id = try store.add(config, password: "fixture-pass")
        let metadata = String(data: defaults.data(forKey: ProxyRepository.preferenceKey)!, encoding: .utf8)!
        check(!metadata.contains("fixture-pass") && !metadata.contains("fixture-user") && !metadata.contains("password"), "no credentials in preferences")
        check(vault.entries[id] == .init(username: "fixture-user", password: "fixture-pass"), "credentials only in vault")
        check(!store.configs[0].enabled && store.configs[0].requiresAuthentication, "save does not auto-enable")
        let restored = repository.load()
        check(restored[0].username == "fixture-user", "username restored from vault")
        config.id = UUID()
        let second = try store.add(config, password: "fixture-pass")
        await store.enable(id)
        check(store.active?.id == id && store.configs.filter(\.enabled).count == 1, "enable one")
        let sharedA = await transport.sessionIdentifier(), sharedB = await transport.sessionIdentifier()
        check(sharedA == sharedB, "HTTP and WS share session identity")
        await store.enable(second)
        check(store.active?.id == second && store.configs.filter(\.enabled).count == 1, "switch preserves single enabled")
        check(store.configs.first(where: { $0.id == id })?.lastStatus != .checking, "switch clears abandoned checking status")
        check(await transport.sessionIdentifier() != sharedA, "session replaced without restart")
        await store.enable(nil)
        check(store.active == nil, "direct disable")
        let direct = try ProxySession.makeSession(config: nil, credentials: nil)
        check(await transport.isDirect(), "direct native configuration")
        let (_, directResponse) = try await transport.data(for: URLRequest(url: fixtureURL))
        check((directResponse as? HTTPURLResponse)?.statusCode == 200, "direct health fixture")
        var networkConfig = ProxyConfig(title: "Fixture", host: "127.0.0.1", port: proxyPort, username: "fixture-user", requiresAuthentication: true)
        let proxied = try ProxySession.makeSession(config: networkConfig, credentials: .init(username: "fixture-user", password: "fixture-pass"))
        defer { proxied.invalidateAndCancel(); direct.invalidateAndCancel() }
        check(proxied.configuration.connectionProxyDictionary?["SOCKSProxy"] as? String == "127.0.0.1", "dictionary host")
        check(proxied.configuration.connectionProxyDictionary?["SOCKSPort"] as? Int == proxyPort, "dictionary port")
        check(proxied.configuration.proxyConfigurations.first?.allowFailover == false, "no silent direct fallback")
        let (_, response) = try await proxied.data(from: proxyTarget)
        check((response as? HTTPURLResponse)?.statusCode == 200, "authenticated SOCKS HTTP transport")
        let delegate = FixtureWebSocketDelegate()
        let ws = proxied.webSocketTask(with: URL(string: "ws://imim-proxy-fixture.invalid:\(httpPort)/signal")!)
        ws.delegate = delegate
        ws.resume()
        try await ws.send(.string("fixture"))
        if case .string(let text) = try await ws.receive() { check(text == "fixture", "authenticated SOCKS WebSocket echo") }
        else { check(false, "unexpected WebSocket payload") }
        for _ in 0..<30 {
            if await delegate.events.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(await delegate.events.count == 1, "shared session task-level socket delegate")
        ws.cancel(with: .normalClosure, reason: nil)
        let (statsData, _) = try await direct.data(from: fixtureURL)
        let stats = try JSONSerialization.jsonObject(with: statsData) as! [String: Int]
        check(stats["authenticatedConnections", default: 0] >= 1 && stats["proxyHealth", default: 0] >= 1 && stats["proxySignal", default: 0] >= 1, "HTTP and WS witnessed by authenticated SOCKS fixture")
        networkConfig.port = closedPort
        let broken = try ProxySession.makeSession(config: networkConfig, credentials: .init(username: "fixture-user", password: "fixture-pass"))
        defer { broken.invalidateAndCancel() }
        var request = URLRequest(url: proxyTarget, timeoutInterval: 2)
        do { _ = try await broken.data(for: request); check(false, "broken proxy must not go direct") }
        catch { check(true, "broken proxy HTTP fails closed") }
        request.url = URL(string: "ws://imim-proxy-fixture.invalid:\(httpPort)/signal")!
        let brokenWS = broken.webSocketTask(with: request); brokenWS.resume()
        do { _ = try await brokenWS.receive(); check(false, "broken WS must not go direct") }
        catch { check(true, "broken proxy WS fails closed") }
        brokenWS.cancel(with: .goingAway, reason: nil)
        let redirectURL = URL(string: fixtureURL.absoluteString + "?redirect=1")!
        let (_, redirectResponse) = try await direct.data(for: URLRequest(url: redirectURL), delegate: ProxyHealthDelegate())
        check((redirectResponse as? HTTPURLResponse)?.statusCode == 302, "health redirect not followed")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { _ = try? await transport.data(for: URLRequest(url: fixtureURL, timeoutInterval: 2)) }
                try? await transport.replace(config: nil, credentials: nil)
            }
        }
        let (_, recovered) = try await transport.data(for: URLRequest(url: fixtureURL))
        check((recovered as? HTTPURLResponse)?.statusCode == 200, "100 concurrent creations/replacements do not invalidate task creation")
        let bad = try store.add(ProxyConfig(title: "Broken fixture", host: "127.0.0.1", port: closedPort), password: "")
        await store.measure(bad)
        check(store.configs.first(where: { $0.id == bad })?.lastStatus == .failed, "health failure marks red status")
        await store.enable(bad)
        for _ in 0..<100 {
            if store.configs.first(where: { $0.id == bad })?.lastStatus == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        check(store.active?.lastStatus == .failed, "enabled wrong-port proxy is red")
        await store.enable(nil)
        let (_, directRecovery) = try await transport.data(for: URLRequest(url: fixtureURL))
        check(store.active == nil && (directRecovery as? HTTPURLResponse)?.statusCode == 200, "wrong-port proxy can turn off and recover direct")
        let savedCount = store.configs.count
        let connected = try await store.connect(preview)
        let repeated = try await store.connect(preview)
        check(connected == id && repeated == id && store.configs.count == savedCount, "confirmed repeated import reuses identical credentials")
        let changed = try ProxyImport.parse(URL(string: "tg://socks?server=127.0.0.1&port=\(proxyPort)&user=fixture-user&pass=changed-fixture-pass")!)
        let changedID = try await store.connect(changed)
        check(changedID != id && store.configs.count == savedCount + 1, "different password does not overwrite previous credentials")
        check(vault.entries[id]?.password == "fixture-pass" && vault.entries[changedID]?.password == "changed-fixture-pass", "old credential entry preserved")
        check(store.configs.filter(\.enabled).count == 1, "confirmed imports keep exactly one enabled")
        await store.delete(changedID)
        var savedA = store.configs.first(where: { $0.id == id })!, savedB = store.configs.first(where: { $0.id == second })!
        savedA.enabled = true; savedB.enabled = true
        do { try repository.save([savedA, savedB]); check(false, "two enabled entries must reject") }
        catch { check(true, "repository refuses simultaneous enable") }
        savedA.requiresAuthentication = true
        let missing = ProxySession(snapshot: .init(config: savedA, credentials: nil, blocked: false))
        do { _ = try await missing.data(for: URLRequest(url: fixtureURL)); check(false, "missing credentials must not go direct") }
        catch { check(true, "missing Keychain credentials fail closed") }
        savedA.enabled = false; savedA.lastStatus = .checking
        try repository.save([savedA])
        check(repository.load().first?.lastStatus == .idle, "restore resets interrupted test")
        try repository.save(store.configs)
        await store.delete(bad)
        await store.delete(id); await store.delete(second)
        check(store.configs.isEmpty && vault.entries.isEmpty, "delete clears metadata/vault")
        // Dedicated random Keychain service/account, removed after test.
        let keychain = ProxyKeychain(service: "chat.imim.proxy.fixture." + UUID().uuidString)
        let keyID = UUID()
        try keychain.write(.init(username: "fixture-user", password: "fixture-pass"), id: keyID)
        defer { try? keychain.delete(id: keyID) }
        check(try keychain.read(id: keyID) == .init(username: "fixture-user", password: "fixture-pass"), "actual Keychain roundtrip")
        try keychain.delete(id: keyID)
        check(try keychain.read(id: keyID) == nil, "actual Keychain deletion")
        print("PASS: \(checks) actual proxy core checks, including authenticated HTTP/WebSocket, closed port, direct recovery, no credential preferences, import validation, isolated Keychain. Mac transport evidence, not iPhone runtime proof.")
    }
}
