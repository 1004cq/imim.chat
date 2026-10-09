# First performance audit verification — 2026-10-08

The initial audit below predates A1/A2. See the subsequent implementation sections for current implementation/build status; baseline SHA values remain intentionally pre-change.

## Verified layer

Code inspection + optimized standalone Mac microbenchmark completed. No App runtime, SwiftUI render, simulator FPS, physical-device trace or before/after App performance claim is made. No production Swift, model, Info.plist, build number, backend, encryption or push code was modified.

Xcode 27.0 (27A266a), Apple Swift 6.4, arm64 Mac host. `xctrace list devices` reported the owner's paired iPhone as **offline**. Asked owner to connect/unlock; no App install or private-data capture occurred.

## Reproduce isolated measurements

From the native Git root:

```sh
xcrun swiftc -O ios/App/App/Date+ChatFormatting.swift \
  ios/App/scripts/ConversationLookupBaseline.swift \
  -o /private/tmp/imim-conversation-lookup-baseline-20261008
/private/tmp/imim-conversation-lookup-baseline-20261008
```

Results: `lookup-baseline-20261008.json`. Seven warm samples; lookup each sample averages 20 traversals, formatter each sample averages 3 batches. Rows are synthetic plain structs, not SwiftData objects. Candidate dictionary construction is INCLUDED in timing and is not installed in App. Assertions cover duplicate-first-match/missing-ID parity; no network, avatar access or message content.

| 500 chats scenario | Current linear scan | Candidate index including construction | Meaning |
| --- | --- | --- | --- |
| All 500 IDs traversed | 0.348 ms, 125250 comparisons | 0.047 ms | Index helps a full traversal in this fixture |
| Last 12 IDs only | 0.014 ms, 5934 comparisons | 0.030 ms | Rebuilding the index can lose for a small visible window |

Actual unmodified `Date.chatListTimeText` formatted 500 dates in **27.598 ms** median on this Mac. This calls the real Foundation extension but excludes SwiftData, filtering, view invalidation, UIKit and rendering. It does not prove a 27.6 ms iPhone frame or establish an FPS improvement.

Decision: reject an unconditional whole-table index rebuild as a blanket fix. Proposed A1 is single transient projection and rows carrying their Chat reference; actual gain remains to be measured after implementation. Formatter reuse is a separate A2 change.

## Source-file preservation

Baseline SHA256 (current dirty working files, not HEAD):

| File | SHA256 |
| --- | --- |
| ChatsView.swift | `3a901d795fd5181fc55e923f98c23606575619eb9dcee43e00b446a2f2ee5e1d` |
| ChatsViewModel.swift | `207903ef5d2a715a60f51a0867310d4b5e3494ae186a8580d72e986db1b16e64` |
| AvatarImageLoader.swift | `b25b939aa3e73674a143cbda3ca9bd11b4362d3359b18056fd9792c8fa9c1b34` |
| Models.swift | `88ef8e4fa9a6ff37daa3a26e3c1a53b1ca40915fa6e18dd657052df08e6dee99` |
| Date+ChatFormatting.swift | `252006a1f3110b9f4a14a5c1476f0fd2c230834af5f2dea5621c633b8f3865aa` |
| Info.plist | `0c1ac38204a21b6ef0229726ee785be6e4a970d60211d4ce6d28eb2ca7bec6c5` |
| project.pbxproj | `e62f7f23bad39882e5c3aa0e1c63b7a8d2d1b5e99180835284305a6b7a856b0b` |

## Pending

- Owner confirmation of A1 implementation.
- Physical-device Release traces with approved fixtures; hitch count/duration, memory peak, first-content timing and actual row invalidation are unmeasured.
- Formatter compatibility regressions and avatar cold-start tracing.
- Full App build is not run for this audit-only change. Standalone benchmark compiled and ran successfully; it is not part of the App target.
- No Git commit/push, TestFlight upload, installation, server access or deployment during this audit.

## A1 implementation — 2026-10-08

Owner confirmed implementation. Production changes are limited to `ChatsView.swift` and `ChatsViewModel.swift`:

- One transient projection in `body` serves empty-state and ForEach; no @State cache or second database.
- Each row carries its original `Chat` next to the immutable display value; no row-level whole-query lookup and no newly built dictionary.
- Existing filters, ranking, titles, subtitles, time formatting, avatar inputs, navigation and action closures remain in use.
- Duplicate fixture IDs do not trap/drop data, and each display value matches its carried object. Existing SwiftUI duplicate-domain-ID behavior is NOT solved or normalized; correcting malformed persisted data is outside A1. For valid unique IDs, targets are exactly the previous original objects.

Artifact directory: `/Users/mima1234/Library/Developer/CodexReleases/imim-listA1.uJ7n5d`.

### Verification

- `bash ios/App/scripts/run-conversation-presentation-regression.sh`: 37 behavior checks passed, plus source assertions for one projection/no row lookup. It compiles actual SwiftData models, actual localization/date helpers and the current projection/filter/pin/delete methods into a standalone Mac executable. Remaining network/crypto methods are excluded; no mocked business projection is substituted.
- Fixtures use an in-memory-only ModelContainer. Compiled App string catalogs verify actual English/Chinese subtitles; user titles remain unmodified. No owner's data or App preferences are touched.
- Warm 500-fixture data-processing comparison is in `regression.log`. This reconstructs the old double-projection + full traversal against current single projection and carried-target consumption. It is not SwiftUI body invocation tracing, an iPhone frame time or an FPS claim. One earlier run overlapped dependency compilation and gave materially different absolute timings; do not compare absolute values across those conditions.
- Final isolated run after the build: legacy 144.232 ms vs A1 40.965 ms, median of 7 warm passes on the Mac. Only the described 500-fixture processing workload is covered; no user-visible speedup percentage is asserted.
- Full workspace `App` / Release / generic iOS / `CODE_SIGNING_ALLOWED=NO` **BUILD SUCCEEDED**. Build log: `build.log`. Third-party SDK/header and existing warnings were not changed as part of A1.
- Date+ChatFormatting.swift, AvatarImageLoader.swift, Models.swift, Info.plist and project.pbxproj hashes still match the audit baseline. Build remains 63; no signing, permissions, encryption or push changes.
- Physical phone remained offline at the last check. No device trace, UI install, TestFlight upload, server change, commit or push was performed. Real scrolling, accessibility and visual compatibility remain device validation items.
- Scoped `list-a1.patch` reverse-application check passed; it contains only the two production file changes relative to their pre-A1 staged snapshot. This was a check only, not a rollback.

### Reproduce / next step

Run the isolated harness above, then capture the same Release device scenarios in implementation-plan.md. Do not claim Telegram-equivalent performance before that capture. Next unimplemented optimization is A2 formatter reuse, subject to explicit scope confirmation and compatibility tests.

## Subsequent release — owner requested “上传”

On 2026-10-08, owner authorized TestFlight upload. Four project Build settings were incremented 63 → 64; marketing version stays 1.0. This is a separate release action after A1, so the earlier project hash/Build-63 preservation statement applies only to the implementation stage.

Signed archive and upload succeeded. Apple processed `1.0 (64)` (`a32e3513-264a-4e83-bfa1-779f70752943`); existing internal test group is associated and bilingual test notes are saved. External Beta App Review was not submitted and the App Store version was not replaced. No physical-device installation or Git commit/push was performed.

Release evidence: `/Users/mima1234/Library/Developer/CodexReleases/imim-list64.nQKbT5/release-status.md`, archive/upload logs and `testflight64.jpg`.

## A2 implementation — further optimization requested 2026-10-08

Production change is limited to `ios/App/App/Date+ChatFormatting.swift`. It reuses at most two DateFormatter instances, preserves the existing HH:mm/MM/dd patterns and Foundation defaults, recomputes today/day selection on each call, and invalidates on locale/calendar/default-timezone changes and locale/system-timezone notifications. No rendered message/date strings are retained. Synchronous formatting/invalidation stay under one NSLock; formatter references do not escape. The private manual Sendable assertion has a documented invariant and a future Mutex migration condition (deployment currently includes iOS 17.x).

### Verified

- `bash ios/App/scripts/run-chat-date-formatting-regression.sh`: **5,832 checks passed**, compiled with Swift 6 and complete strict concurrency. Uses the actual production helper, not a replacement formatting implementation.
- Default-output parity compares the App Date extensions with their reconstructed original DateFormatter behavior. Configured fixtures cover seven locales, three calendars, five time zones, DST/leap-date samples, pattern reuse, context changes, notifications and observer deallocation. These configured fixtures do not imply actual iOS system preferences were changed/tested on a device.
- Live default-timezone transitions occur only inside the standalone process; macOS preferences and owner's App data are not modified.
- Concurrent formatting plus notification invalidation: 2,048 iterations passed. `CHAT_DATE_TSAN=1 bash ios/App/scripts/run-chat-date-formatting-regression.sh` passed with Thread Sanitizer, no reported race. Sanitized timings are not used for the performance comparison.
- Final non-sanitized Mac run, after the iOS build completed: 500 synthetic dates, seven warm samples, three batches/sample; reconstructed legacy **28.261236 ms** versus actual cached helper **1.543542 ms** median. Twenty subsequent warm batches constructed **zero** new formatters. This is formatter/data processing only, NOT FPS, launch timing, SwiftUI updates or iPhone rendering.
- Existing conversation presentation regression: **37 checks passed**, including compiled Chinese/English resources, sorting/search, original action targets, and metadata updates.
- Full `App.xcworkspace` / `App` / Release / generic iOS / CODE_SIGNING_ALLOWED=NO: **BUILD SUCCEEDED**. No new date-helper diagnostic was observed; existing third-party warnings were not repaired in this task.
- ChatsView, ChatsViewModel, Models, AvatarImageLoader, Info.plist and project.pbxproj hashes match this turn's pre-change snapshot. Project Build remains 64; marketing version remains 1.0.
- Bounded production `date-a2.patch` reverse check passed without applying it. Tests and docs are separate changes; no existing user staging was modified.

Artifacts: `/Users/mima1234/Library/Developer/CodexReleases/imim-listA2.J9fURF` contains build.log, date-regression.log, date-tsan.log, conversation-regression.log, date-a2.patch and receipt.md.

### Not verified / not performed

The paired physical iPhone still reports offline. No real-device frame/hitch/launch measurement, simulator App UI run, installation, TestFlight archive/upload, server change, commit/push or App Store review change was performed in A2. Build 64 already uploaded before A2 and the currently submitted Build 63 do not include this new formatter change. A new build/upload requires a separate owner request.

## A3 implementation — further avatar optimization requested 2026-10-08

Only production `ios/App/App/AvatarImageLoader.swift` changed in this turn. Repeated generated fallback bitmaps are reused by a MainActor-owned NSCache configured with 128-entry and 4 MiB cost limits. Keys distinguish original initial/group, effective renderer size/scale/range, light/dark, contrast, interface level, gamut/legibility and language context. Cache cost uses actual CGImage row bytes and height. NSCache limits are advisory, not an App RSS guarantee. Downloaded peer images, URLs and conversations are not stored in a new cache.

SHA256 remains the same; only 32 String(format:) byte conversions are replaced by lower-case hexadecimal byte lookup. Persisted avatar source/key digests remain byte-identical. Download lifecycle, stable userId/path keys, memory/disk lookup, immediate disk-hit policy, historical source guard, stale completion handling, visible priority, concurrent download limit and avatar layouts are unchanged.

### Verification and reproduction

- `bash ios/App/scripts/run-avatar-performance-regression.sh prefetch`: **19 checks plus 5 restore checks passed both before and after**. The restore stage is a separate executable process with empty memory, using the same isolated test disk cache and UserDefaults suite. No owner cache or live server is used; test downloads are intercepted by URLProtocol.
- The runner freshly compiles the project's current Kingfisher source into a temporary Catalyst library, streams the actual loader/store/models/theme/localization and existing AVATAR_PREFETCH_TESTS harness to the compiler. It excludes Kingfisher documentation snippets, which are not library source. No project target, dependency or SDK setting is added/changed.
- `bash ios/App/scripts/run-avatar-performance-regression.sh cost --expect-reuse`: **511 checks passed**. It exercises the actual loader, compares full raster RGBA data/size/scale to the reconstructed previous renderer across names (including whitespace/Chinese/emoji), groups, sizes, light/dark and high contrast, and verifies immediate bitmap-object reuse. Digest fixtures match the original Foundation hex encoder exactly.
- Synthetic warm Mac Catalyst workload, seven samples: 500 fallback loads **63.460667 → 2.603708 ms**; 500 revision digests **15.191417 → 0.394542 ms**. These exclude network and real App SwiftUI scrolling; they do not measure iPhone cold start, IO hitches or FPS.
- A2 date harness again passed **5,832 checks**; A1 presentation harness again passed **37 checks**, including compiled English/Chinese resources and original SwiftData targets.
- Full App / unsigned iOS Release build **BUILD SUCCEEDED**, with no reported new AvatarImageLoader diagnostic. Existing dependency warnings were not repaired by this task.
- Pre-existing staged AvatarImageLoader work was preserved. Date helper, ChatsView/ChatsViewModel, Models, DoveTheme, AvatarStore, AvatarPrefetchRegression, Info.plist and project file hashes remain identical to this turn's pre-change snapshots.
- `avatar-a3.patch` bounded reverse-application check passed; no rollback was applied. Git diff whitespace checks passed.

Artifacts: `/Users/mima1234/Library/Developer/CodexReleases/imim-listA3.IQKIAk` contains prefetch-before/after.log, cost-before/after.log, date-regression.log, conversation-regression.log, build.log, avatar-a3.patch and receipt.md.

### Limits / next evidence

Paired iPhone still reports offline. UIKit Catalyst regression is not a device visual/performance trace. The main-actor synchronous disk image read/decode path remains as before to preserve the disk-hit first-frame contract; async-only replacement needs an explicit cold-frame tradeoff decision and profiling. No install, archive/upload, build bump, App Store review action, server mutation or Git commit/push occurred. Existing uploaded Build 64 and submitted Build 63 remain unchanged and do not include A2/A3.

## B1 implementation — further optimization requested 2026-10-09

Only production `ios/App/App/ChatDetailView.swift` changed in this turn.
The existing main-queue-delayed bottom scroll now passes through a view-owned
value-only policy. Requests pending before the next delivery are coalesced;
initial positioning takes precedence and stays nonanimated, outgoing intent
retains its existing ability to jump from history. Incoming/history requests
are admitted only near bottom. User scrolling cancels pending work, and delivery
rechecks user interaction/ticket identity. View disappearance cancels pending work.
Reduce Motion disables this automatic scroll animation.

Native iOS 18+ phases include tracking/interacting/decelerating but not
programmatic animating. The iOS 17 fallback observes simultaneous touch drag via
GestureState; it does not detect post-release inertia. No new UIKit list engine,
history pagination or pixel-offset anchoring is introduced. The non-lazy VStack,
domain message IDs, row action targets, existing sorted snapshot and 100-point
near-bottom threshold remain unchanged. No message/content/persistence cache exists
in the policy.

### Verified

- `bash ios/App/scripts/run-chat-bottom-scroll-regression.sh`: **151 checks passed**
  with the actual policy extracted from the production source, compiled using
  Swift 6 and complete strict concurrency. No replacement policy or owner data.
- Admission/delivery timing, canceled/stale callbacks, initial/outgoing priority,
  no automatic replay after drag, repeated requests and Reduce Motion are covered.
  Source assertions verify the actual View's wiring, cancellation, phases/fallback,
  unchanged stable IDs/VStack and sorted-message call. These source assertions are
  not an end-to-end SwiftUI gesture test.
- A synthetic 1000-request burst before delivery admits **one** callback, rather
  than the old scheduler's one unconditional queued action per call. This is
  policy behavior, not actual network throughput, frame/hitch/FPS measurement.
- Appended tall media can itself move the bottom outside the threshold. Delivery
  therefore rechecks user intent rather than wrongly rejecting an already-admitted
  request merely because new content increased bottom geometry.
- Original conversation/localization harness: **37 checks passed**; original
  formatter harness: **5,832 checks passed**. Their synthetic timings are not used
  as B1 performance evidence.
- Final full `App.xcworkspace` / `App` / unsigned Release / generic iOS build:
  **BUILD SUCCEEDED**. Existing AppIntents metadata extraction warning remains;
  no new ChatDetailView compiler diagnostic was observed.
- ChatDetailViewModel, Models, Info.plist and project hashes match this turn's
  baseline. Build remains **65**, marketing version **1.0**. The pre-existing
  ChatDetailView staged blob `a672583b807b9b5f8a9fcba229e5e5c4113610b0` is preserved.
- Production bounded patch reverse check passed without applying it; whitespace
  checks passed. Final ChatDetailView SHA256:
  `9da0add29e02b9fc1476668e28f2fb9d7cc878c8bcd74ce0951ec46c0f2db9fb`.

Artifacts: `/Users/mima1234/Library/Developer/CodexReleases/imim-chatB1.8U0pzb`
contains scroll/conversation/date regression logs, build-final.log,
ChatDetailView.before.swift, chat-b1.patch and receipt.md.

### Still unverified / not performed

Xcode currently sees the paired iPhone online, unlike previous A2/A3 checks.
No installation or private-chat trace was performed: the installed/released
Build 65 predates B1. Real-device user drag/deceleration, keyboard/media updates,
visible message offset and hitch behavior require an approved fixture/UI run.
The code-backed deferred-scroll risk is reduced; this is not proof that every
prior blank-gap/jump symptom is resolved. No Git commit/push, TestFlight upload,
build bump, App Store change or server mutation was performed in this turn.

## D1 / B2 implementation — maximum further optimization, 2026-10-09

Only production `ChatDetailView.swift` and `VoiceMessageViews.swift` changed.

- Chat image previews no longer read whole files or instantiate original-size
  UIImage on MainActor. A serial actor reads the ImageIO source and decodes an
  orientation-transformed, display-pixel thumbnail, capped at a 4096px edge and
  approximately four megapixels (ImageIO pixel rounding applies). No persistent
  plaintext thumbnail cache. Existing 190x140 layout/auth/retry/decryption stay.
- Task identity covers URL, target pixels and content mode. Cancellation is
  checked before/after decoding and before publication; disappearance releases
  the thumbnail. Synchronous ImageIO cannot be interrupted mid-call: cancellation
  discards its result afterward. Source guards are not runtime reuse testing.
- Chat UI owns a filtered recording observer wrapping the SAME audio manager.
  Only start/stop/errors notify the screen; meter/cancel state stays in the small
  recording overlay. Message rows no longer observe the entire recorder. The
  voice child projects matching messageId/isPlaying/progress and deduplicates.
  VoiceRecorderManager and its audio session/playback/recording timers are untouched.
- Wave phase derives from the existing TimelineView date, not a retained
  repeatForever state animation. The timeline pauses for stop and Reduce Motion;
  progress/bar dimensions/colors/actions remain. No visibility virtualization
  or renderer replacement is claimed.

### Verified on final source

- `run-chat-image-decode-regression.sh`: **46 checks**; actual production actor
  extracted and compiled under Swift 6 complete strict concurrency. Synthetic
  4000x3000 JPEG becomes 570x427, **976,976 raster bytes (~0.93 MiB)**; full-size
  4-byte RGBA reference is 48,000,000 bytes (~45.8 MiB). This is decoded thumbnail
  size, not measured legacy UIImage allocation, peak process RSS or App FPS.
  JPEG/file/data parity, eight orientation dimension cases, PNG alpha, small
  image/no-upscale, fit/fill, extreme dimensions, invalid input, precancellation
  and off-UI-thread assertions pass. Owner data/network/cache are not accessed.
- `run-chat-voice-observation-regression.sh`: **28 checks**, actual production
  projection/clock source compiled under Swift 6 complete strict concurrency.
  A declaration-matched publisher fixture models the unchanged audio manager,
  not AVAudioPlayer. **500 playback ticks: chat 0, inactive voice 0, active voice
  500 updates**; broad original publisher emits 500. **500 recording ticks / 1500
  field writes: chat 0 updates**. Start/stop/errors, switch/reset/joining state,
  duplicate suppression, weak subscription lifetime and motion/clock cases pass.
  View source assertions check recording child, playback child and unchanged
  playback action wiring. This is not a SwiftUI render or audible-device test.
- Existing B1 scroll **151**, A1 conversation/localization **37**, A2 date **5,832**
  checks passed again. Total counted behavioral checks: **6,094**.
- D1 alone, subsequent voice refactor and final full unsigned iOS Release builds
  all **BUILD SUCCEEDED**. Final source build: `build-final.log`; existing AppIntents
  extraction warning remains, no new source diagnostic observed.
- VoiceRecorderManager, ChatDetailViewModel, Models, Info.plist and project hashes
  match the before-change snapshot. Pre-existing index blobs for ChatDetailView
  (`a672583b807b9b5f8a9fcba229e5e5c4113610b0`) and VoiceMessageViews
  (`536655e28ea60a8b0e8aafc48c1917d367e74e50`) are unchanged. Build **1.0 (65)**.
- Bounded `media-voice.patch` reverse check passed without applying rollback;
  scoped whitespace checks passed. Final hashes:
  ChatDetailView `fa30735a1e62d6e79cea1b2a832949ab41aec0860b0a79e985b3f748839a3763`;
  VoiceMessageViews `879a53baa9efac3759f2ffbb9f010ef21364325f99143d03a4fc1bf86dadb519`.

Artifacts: `/Users/mima1234/Library/Developer/CodexReleases/imim-mediaD1.WxBTCU`
contains before-source snapshots, image/voice/scroll/conversation/date regression
logs, staged build logs, final build log, bounded patch and receipt.

### Remaining runtime work

No install/archive/TestFlight upload, Git commit/push, review or server mutation.
Released/installed Build 65 predates these changes (and B1). No owner private
conversations were opened/profiled. Device validation still needs approved long
mixed-message fixtures: image scroll/reappearance/URL swap while decoding,
start/cancel/send recording, switching/finishing voice playback, keyboard/input,
Reduce Motion, memory/IO/hitch traces. Historical prepend pixel-offset anchoring
and long-chat virtualization are still separate work; this is not a claim of
Telegram-equivalent or maximized whole-App performance.
