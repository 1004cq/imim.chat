# iOS source snapshot — 1.0 (65), 2026-10-09

This branch publishes the current native iOS source, with the owner's approval,
onto `1004cq/imim.chat` without changing `main`. Its base is
`aff50146fc70f583ca3fa554146a39e2dfdf2c09` (the older Build 31 tree).
Consequently, this is a complete iOS source synchronization, not just the three
bounded performance patches. Existing client functionality, localization,
notification extension and regression harnesses are included as they were in
the signed Build 65 archive; they were not reimplemented during synchronization.

## Included and excluded

Included: `ios/App/App`, `ios/App/NotificationService`, shared Xcode project and
workspace configuration, `Podfile`/`Podfile.lock`, first-party regression scripts,
and performance documentation. Application image/audio resources are included.

Excluded: credentials, provisioning profiles, private keys, user-specific Xcode
state, downloaded SDKs/Pods, DerivedData, archives, compiled products and generated
legacy Capacitor web output. No backend, Nginx, Compose, MTProto or push-provider
changes are part of this snapshot. The original working directory and its index
are untouched by this Git publication.

## Restore dependencies before building a fresh checkout

The project deliberately retains the existing local Swift package reference
`ios/App/Packages/Kingfisher`. The installed dependency's podspec identifies
Kingfisher 8.12.0, from `https://github.com/onevcat/Kingfisher.git`. Restore the
existing compatible package there (or obtain and validate that upstream version)
before resolving packages. SDK source is not vendored in this branch. The local
installation has not been asserted to be byte-identical to an upstream tag.

Run `pod install` inside `ios/App` to restore the locked TRTC SDK version
13.5.21355, then open `App.xcworkspace`. Other remote Swift package revisions are
recorded in the committed `Package.resolved` files. Use full Xcode, not just
Command Line Tools. Signing credentials remain outside Git.

## Verification boundary

The original dependency-equipped native checkout produced a signed 1.0 (65)
archive and passed strict signature verification. Apple accepted and processed
the TestFlight upload; both App and NotificationService are Build 65.

The synchronized source is checked against that native tree and the standalone
date/conversation regression harnesses are rerun here. This does not establish
that a dependency-empty fresh clone builds before restoration, nor does it
establish physical-device FPS, notification delivery or media-call behavior.
Detailed optimization checks and synthetic measurement limits are in
`verification.md`.

This publication does not withdraw or replace any App Store review submission,
submit an external TestFlight review, install on a phone or deploy a server.
