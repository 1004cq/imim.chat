# imimchat performance execution plan

## Objective and scope

Improve responsiveness without replacing SwiftData, Kingfisher, encryption, networking or the App's visual identity. Owner confirmed A1 implementation with “开始” on 2026-10-08 and further optimization with “帮我优化” / “继续优化” later that day. A1 list presentation, A2 formatter reuse and A3's generated-avatar/revision presentation cost reduction are implemented. Blocking disk cold-path tradeoffs and later phases remain separate work.

Actual root: `/Users/mima1234/Documents/ininchatios/imimchatios`. Branch `codex/e2ee-repair-20261004`, HEAD `8083e675a3e942f73234ff0a014c733d55305a30`. Substantial staged and unstaged App changes already exist; compare against the current working files, not HEAD alone. Archives and SDK files also appear in existing staged work; do not clean, commit or broadly stage them during this task.

## Progress

- [x] Verify native root, branch, dirty state, SwiftData query, existing avatar pipeline and full Xcode.
- [x] Clone sparse official Telegram source and freeze verified commit.
- [x] Inspect and document relevant entry/transition/layout/avatar symbols.
- [x] Run optimized, synthetic Mac lookup benchmark and actual Date extension timing.
- [x] Prepare real-device test matrix and note current phone offline.
- [x] Confirm first production change with owner.
- [ ] Capture comparable device baseline using test data.
- [x] Implement A1 and add isolated SwiftData behavior regressions.
- [x] Build unsigned iOS Release successfully and compare standalone projection timings.
- [x] Implement A2 with default-output/context/invalidation regressions, strict Swift 6 compilation, Thread Sanitizer, and full unsigned Release build.
- [x] Implement A3 placeholder reuse/digest encoding with raster compatibility, before/after actual-source prefetch/disk-restore harness and full unsigned Release build.
- [ ] Verify actual SwiftUI row invalidation, scrolling and interaction behavior on a physical device.

## A1 — first proposed low-risk change

Candidate files: `ChatsView.swift`, `ChatsViewModel.swift`, standalone regression test. No `Chat` schema, avatar, API or crypto changes.

1. Construct a transient list presentation once per body evaluation, instead of evaluating `conversations` again for emptiness and iteration.
2. Carry the corresponding `Chat` and existing immutable display model together. Keep stable `chatId` identity and original navigation/action targets.
3. Eliminate each row's `chats.first(where:)`, avoiding an unconditional whole-table dictionary on every redraw. Define duplicate/missing-ID compatibility explicitly.
4. Do not add persistent display state or an arbitrary @State cache; SwiftData remains authoritative and all property changes must reach rows.
5. Keep filters, search, official/AI fixed order, ordinary pinning/deletion, unread behavior, title, time, preview, localization and avatar peer ID.

Acceptance: projection called once per render invocation; no repeated row lookup; existing actions use the same Chat; all/ group/search/empty states, language switching, realtime preview changes and avatar updates continue to work. Actual hitch improvement requires a trace, not just a faster isolated lookup.

## A2 — formatter and projection cost

Reuse formatting machinery safely or use value-style formatting only after confirming identical output. Test today vs older day, day boundary, timezone, locale, Chinese/English and calls from other screens. Do not introduce unsafe shared mutable DateFormatter state. Avoid claiming the microbenchmark's 27.6 ms is the device frame time.

Owner requested further optimization on 2026-10-08. A2 is now in scope: retain the two existing format patterns and Foundation defaults, but reuse at most two formatters. Serialize synchronous cache access, rebuild on locale/calendar/default-timezone changes, and invalidate on system locale/timezone notifications. Recompute the today-vs-older-day choice on each call; do not cache rendered dates, messages, or SwiftData values. Keep the synchronous Date extension API and all callers unchanged.

The project uses Swift 5 language mode and iOS 17.x deployment targets, with no explicit default actor isolation or strict-concurrency override in the project file. A private NSLock-protected cache is appropriate for this existing synchronous Foundation API; no actor hop or SwiftData transfer is introduced. If `@unchecked Sendable` is needed, all mutable state and DateFormatter use must remain inside the lock, and formatter references must never escape. When the deployment floor permits Synchronization.Mutex, migrate ownership to that checked primitive and remove the manual Sendable assertion.

A2 acceptance: legacy-output parity, today/day-boundary selection, locale/calendar/timezone fixtures, live default-timezone changes, notification invalidation, bounded formatter construction, concurrent formatting/invalidation, the existing A1 behavior harness, and a full unsigned iOS Release build. Mac microbenchmarks remain synthetic; no install, upload, review cancellation/replacement, server change, commit or push is included.

## A3 — avatar cold path

Measure memory hit, disk-only process restart, download miss and changed URL separately. Preserve instant memory hit, no spinner, stable identity, visible priority, old-image retention, request coalescing, disk persistence and stale-completion guards. Explore asynchronous prewarming/fixed placeholder policy only after discussing the cold-first-frame tradeoff. Existing AVATAR_PREFETCH_TESTS harness must be run before/after a loader change.

Owner requested "继续优化" on 2026-10-08. A3 now targets two measured presentation costs, not the synchronous disk-first behavior: reuse generated fallback images in a MainActor-owned NSCache (128 entries, 4 MiB configured cost limit; appearance/size/scale/initial/group/language keyed), and preserve SHA256 source/key digests while replacing 32 per-byte Foundation format operations with equivalent hexadecimal byte encoding. No downloaded-peer image cache, model or persistence schema is added. The existing Kingfisher stable-key cache and all download/revision/stale-completion decisions stay unchanged.

Before change: the actual-source Catalyst prefetch harness passed 19 checks plus 5 disk-restore checks in a second process. An actual loader synthetic cost test measured 500 placeholder loads at 63.460667 ms and 500 source digests at 15.191417 ms median on this Mac; neither is real App scrolling/launch evidence. Acceptance includes full-raster parity against the prior renderer, trait/size/name changes, digest compatibility, after-change prefetch/restore regressions and full unsigned Release compilation.

## Later phases, not yet fully audited

B: chat-history insertion + visible anchor preservation; C: keyboard/emoji/sticker state and insets; D: media dimensions/thumbnail/cover/finite prefetch; E: interruptible tab gestures/animations. Each needs its own source mapping and baseline before changes. No broad UIKit/AsyncDisplayKit migration is authorized.

## Device verification matrix

Use dedicated synthetic/approved test data, not owner private conversations; an isolated in-memory ModelContainer/test target may be proposed, but do not seed or erase the owner's store. No automatic production API calls.

| Case | Interaction | Evidence |
| --- | --- | --- |
| Local first | Warm-cache restart; offline restart | First-content/interactive timing, no empty-network gate |
| 500 chats | 20 seconds repeated top/bottom scrolling | SwiftUI update cost, Time Profiler, hitch duration/count, memory |
| Narrow update | Change one unread/preview while scrolled | Row updates and scroll position; no stale display |
| Avatars | Memory hit, disk-only restart, miss, update one user | IO/decode stacks, request counts, unchanged peers |
| UI compatibility | Search/groups, pin/delete, Chinese/English, larger text | Stable identity, correct action target, screenshots |
| Later chat work | 1000 mixed messages, prepend history, keyboard changes | Visible message ID + offset before/after; no forced bottom jump |

Same physical device, OS, Release configuration, fixture, power/thermal conditions and cache state before/after. Capture 3 repeats; do not combine unrelated interactions into one trace. Measure high-refresh and normal modes as applicable; do not hardcode a 120 FPS promise.

## Handoff / rollback

Initial audit changed only AGENTS.md, documents and a standalone synthetic benchmark. A1 subsequently changed only `ChatsView.swift` and `ChatsViewModel.swift` in production, plus its isolated harness and documentation. A2 subsequently changed only `Date+ChatFormatting.swift` in production; A3 changed only `AvatarImageLoader.swift`. Bounded patches are saved in the artifact directories recorded in verification.md; reverse only those hunks if needed, never reset the existing dirty working tree. Installing/uploading/submitting is a separate owner request.
