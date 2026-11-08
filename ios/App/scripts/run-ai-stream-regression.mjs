// Executes the actual production parser and HTTP method against URLProtocol
// fixtures. No real HTTP requests, credentials, packages or paid calls.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = readFileSync(path.join(app, 'App/APIClient.swift'), 'utf8');
const viewModel = readFileSync(path.join(app, 'App/ChatDetailViewModel.swift'), 'utf8');
const loading = viewModel.slice(viewModel.indexOf('func loadMessages('), viewModel.indexOf('private func rememberSenderAvatars'));
assert.ok(loading.includes('if AIConversation.matches(chat.chatId) { errorMessage = nil; noticeMessage = nil; return }'));
assert.ok(loading.indexOf('AIConversation.matches') < loading.indexOf('E2EEManager.shared'));
const readReceipt = viewModel.slice(viewModel.indexOf('func markAsRead('));
assert.ok(readReceipt.indexOf('if AIConversation.matches') < readReceipt.indexOf('sendReadReceipt'));
assert.ok(source.includes('ProxySession.shared.bytes(for: request)'));
console.log('PASS: source guards route AI away from private history/receipts and through the existing proxy transport');
function declaration(marker) {
  const begin = source.indexOf(marker);
  if (begin < 0) throw new Error('Missing declaration: ' + marker);
  let end = source.indexOf('{', begin) + 1, depth = 1;
  while (depth && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  return source.slice(begin, end);
}
const production = ['enum AIConversation', 'struct AIChatTurn:', 'struct AIStreamDecoder', 'enum APIClientError:', 'struct APIErrorResponse:']
  .map(declaration).join('\n');
const method = declaration('@MainActor\n    func streamAIReply');
const fixture = String.raw`
import Foundation

actor ProxySession {
    static let shared = ProxySession()
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await URLSession.shared.bytes(for: request)
    }
}

@MainActor final class AuthTokenStore {
    static let shared = AuthTokenStore()
    var token: String? = "synthetic-user-token"
}
final class FixtureProtocol: URLProtocol {
    static var mode = "success"
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "ai-fixture.invalid")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-user-token")
        Self.requests += 1
        let status = Self.mode == "unconfigured" ? 503 : 200
        let body: String
        switch Self.mode {
        case "unconfigured": body = #"{"error":"synthetic unconfigured"}"#
        case "incomplete": body = "event: delta\ndata: {\"text\":\"partial\"}\n\n"
        case "error": body = "event: error\ndata: {\"error\":\"synthetic failure\"}\n\n"
        default: body = ": ping\r\n\r\nevent: delta\r\ndata: {\"text\":\"你好\"}\r\n\r\nevent: delta\r\ndata: {\"text\":\" fixture\"}\r\n\r\nevent: done\r\ndata: {}\r\n\r\n"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Regression {
    @MainActor static func main() async throws {
        URLProtocol.registerClass(FixtureProtocol.self)
        precondition(AIConversation.matches("bot") && AIConversation.matches("cBOT"))
        precondition(!AIConversation.matches("private-peer") && !AIConversation.matches("official"))
        precondition(AIConversation.messagePrefix(owner: "owner") != AIConversation.messagePrefix(owner: "other-owner"))
        let api = FixtureAPI()
        var updates: [String] = []
        let turns = [AIChatTurn(role: "user", content: "synthetic question")]
        let answer = try await api.streamAIReply(turns: turns) { updates.append($0) }
        precondition(answer == "你好 fixture" && updates.last == answer)
        for mode in ["incomplete", "error", "unconfigured"] {
            FixtureProtocol.mode = mode
            do { _ = try await api.streamAIReply(turns: turns) { _ in }; fatalError("Expected failure: " + mode) }
            catch { precondition(!error.localizedDescription.isEmpty) }
        }
        AuthTokenStore.shared.token = nil
        do { _ = try await api.streamAIReply(turns: turns) { _ in }; fatalError("Expected auth failure") }
        catch { precondition(FixtureProtocol.requests == 4) }
        print("PASS: production native streaming HTTP/parser; byte-split UTF8 + CRLF + blank events; partial UI; truncated/error/missing config fail; signed-out makes no request")
    }
}
`;
const directory = mkdtempSync(path.join(tmpdir(), 'imim-ai-stream-'));
const swift = path.join(directory, 'Regression.swift');
writeFileSync(swift, fixture + '\n' + production + '\nclass FixtureAPI {\nprivate let baseURL = "https://ai-fixture.invalid/api"\n' + method + '\n}\n');
const binary = path.join(directory, 'Regression');
const build = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', swift, '-o', binary], { stdio: 'inherit' });
if (build.status !== 0) process.exitCode = build.status ?? 1;
else process.exitCode = spawnSync(binary, [], { stdio: 'inherit' }).status ?? 1;
