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
