# iOS source and TestFlight candidate — 1.0 (67), 2026-10-10

This update continues `codex/ios-source-performance-20261009`; `main` is not
merged or overwritten. The native working checkout and its existing index are
preserved; this clean publication checkout receives only reviewed first-party
source, tests and documentation. Dependency restoration requirements from
`ios-source-snapshot-65.md` still apply to a fresh clone.

## Changes since the Build 65 source snapshot

- Build 67 (marketing 1.0 unchanged), source registrations for ProxySession and
  ProxySettingsView; imim URL scheme, existing background modes unchanged.
- Refreshed compact login, Chinese/English/system language, password/SMS forms,
  independent registration entry, Proxy status shortcut, scalable light/dark UI.
  Google/Apple sign-in intentionally not enabled pending backend/configuration.
- App-only SOCKS5 metadata locally, credentials in device Keychain. Shared
  APIClient/SocketManager URLSession, explicit switching/direct recovery,
  single enabled entry, fixed-origin health latency/status, no direct failover.
- Strict imim/app-domain/Telegram SOCKS link parsing, item-driven preview,
  masked password, explicit test/Connect, canceled import without saving.
  Repeated identical credentials reuse an entry; changed credentials preserve
  old entries. No automatic connection from links and no screenshot server used.
- Chat B1 bottom-scroll intent/coalescing; D1 ImageIO bounded thumbnails; B2
  voice observation scoped to affected rows. Independent implementations based
  on pinned references, not copied Telegram code or an architecture migration.

## Security and scope

No backend, Nginx, Compose, APNs, Signal/MLS, TRTC media transport, system tunnel
or new third-party dependency change. No secrets, SDK/Pods downloads, private
keys, provisioning profiles, archives, compiled products, legacy web output or
user-specific Xcode state are committed. SOCKS currently covers APIClient HTTP/
uploads/type probes and SocketManager WebSocket only, not every standalone or
third-party avatar/media downloader. HTTPS/tg links are imported from in-app taps
or pasted links, not by claiming Telegram's domains or URL scheme externally.

## Verification

The dependency-equipped native tree passed generic iOS Release builds. Proxy core
compiled under Swift 6 complete concurrency and passed 80 isolated fixture checks;
login passed 43 source/catalog/contrast guards before the release-only Build bump.
Existing API/auth/notification boundaries were verified unchanged during those
feature turns. Device login/proxy routes/keyboard/Dynamic Type and performance
FPS are not established by those source/fixture results.

Reproducible tests:

```sh
bash ios/App/scripts/run-proxy-session-regression.sh
bash ios/App/scripts/run-chat-bottom-scroll-regression.sh
bash ios/App/scripts/run-chat-image-decode-regression.sh
bash ios/App/scripts/run-chat-voice-observation-regression.sh
```

The proxy fixture only tunnels its own synthetic target to a local HTTP/WebSocket
server, rejecting all other destinations. Its random UserDefaults suite and
fixture-only Keychain service do not touch a user's account or normal credentials.

This source update does not withdraw or replace any App Store review submission.
Archive/upload/Apple processing results are recorded separately outside Git.
