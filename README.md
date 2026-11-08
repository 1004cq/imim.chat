# imimchat native iOS

Native iOS source corresponding to published Build 80, plus the scoped E2EE reliability fixes in Build 81. Marketing version remains 1.0.

## Build

Use Xcode 27.2 and the existing signing team. Restore the same dependency versions before opening `ios/App/App.xcworkspace`:

```sh
git clone --branch 8.12.0 --depth 1 https://github.com/onevcat/Kingfisher.git ios/App/Packages/Kingfisher
cd ios/App
pod install --deployment
open App.xcworkspace
```

`Podfile.lock` pins TRTC 13.5.21355. Kingfisher is the same local-package dependency as the published Build 80. Do not commit dependency caches, Pods, provisioning profiles, private keys or build products.

## Scoped regression checks

```sh
node ios/App/scripts/run-e2ee-security-regression.mjs /path/to/imimchat/client/src/lib/e2ee/CryptoUtils.ts
node ios/App/scripts/run-encrypted-message-retry-regression.mjs
node ios/App/scripts/run-mls-epoch-regression.mjs
node ios/App/scripts/run-mls-store-regression.mjs
node ios/App/scripts/run-mls-security-regression.mjs
node ios/App/scripts/run-group-send-flow-regression.mjs
bash ios/App/scripts/run-release-chat-regression.sh
```

Fixtures use synthetic keys and in-memory stores. Passing them does not establish live multi-device delivery or APNs acceptance.
