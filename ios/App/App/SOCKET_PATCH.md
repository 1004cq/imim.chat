# Do not merge this PR until SocketManager.swift is restored

A partial upload overwrote `ios/App/App/SocketManager.swift`. Restore it from `main` first, then apply only this change.

Replace the `url` property and `connect()` socket creation with:

```swift
private var signalURL: URL {
    URL(string: "wss://wed.imim.chat/signal")!
}

private func makeSocketRequest() -> URLRequest? {
    guard let token = AuthTokenStore.shared.token, !token.isEmpty else { return nil }
    var request = URLRequest(url: signalURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
}
```

In `connect()`:

```swift
guard let request = makeSocketRequest() else { return }
let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
webSocketTask = session.webSocketTask(with: request)
```

Do not put `token` or `userId` in the WSS query string.
