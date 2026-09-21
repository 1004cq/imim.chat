import Foundation
import Combine

class SocketManager: NSObject, ObservableObject {
    static let shared = SocketManager()

    @Published var isConnected = false
    @Published var lastReceivedMessage: Message?

    private var webSocketTask: URLSessionWebSocketTask?
    private var signalURL: URL {
        URL(string: "wss://wed.imim.chat/signal")!
    }

    private func makeSocketRequest() -> URLRequest? {
        guard let token = AuthTokenStore.shared.token, !token.isEmpty else { return nil }
        var request = URLRequest(url: signalURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    private var pingTimer: Timer?
    private var reconnectWorkItem: DispatchWorkItem?
    private var isBackgrounded = false
    private var reconnectEnabled = false
    private var lastEncryptionResetRequest: [String: Date] = [:]

    private override init() {
        super.init()
    }

    func connect() {
        guard !isBackgrounded,
              AuthTokenStore.shared.token?.isEmpty == false else {
            return
        }

        reconnectEnabled = true
        closeConnection()
        guard let request = makeSocketRequest() else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
        startPinging()
    }
