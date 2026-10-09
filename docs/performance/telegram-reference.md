# Telegram source reference — audit 2026-10-08

## Fixed reference and limits

- Official repository: https://github.com/TelegramMessenger/Telegram-iOS
- Local checkout: `/Users/mima1234/Documents/reference-sources/Telegram-iOS`
- Commit: `6ad963e5b62d354da79040f388ae2b9132fb17b8`
- Sparse checkout of relevant Swift files and root README; no recursive dependency download, project generation, build scripts or Telegram services were run.
- Reference worktree verified clean. Only the symbol ranges below were inspected, not the entire repository.
- Official licensing declaration: https://telegram.org/apps#source-code lists Telegram iOS as GPL v2 or later. Individual third-party components can differ. This audit copies no Telegram code into the App and makes no assertion that translating GPL code removes obligations.

## Verified source mappings

| Mechanism | Verified source | imimchat mapping / decision |
| --- | --- | --- |
| Stable domain identity | [ChatListNodeEntries.swift lines 455–471](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/ChatListUI/Sources/Node/ChatListNodeEntries.swift#L455-L471), `ChatListNodeEntry.stableId` | Keep `chatId` identity. No random IDs. imimchat's `Chat` currently has no unique attribute; any proposed lookup must explicitly preserve or test duplicate handling rather than using a trapping dictionary initializer. |
| Old/new entry transition | [ChatListViewTransition.swift lines 37–55](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/ChatListUI/Sources/Node/ChatListViewTransition.swift#L37-L55), `preparedChatListNodeViewTransition` | Observe how delete/insert/update operations are represented. Keep SwiftData + SwiftUI's diffing; do not transplant Telegram's transition system. |
| Prepare transition, apply on UI queue | [ChatListNode.swift lines 2668–2677](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/ChatListUI/Sources/Node/ChatListNode.swift#L2668-L2677) | Telegram chooses a processing queue, then delivers application to main. This is not permission to move SwiftData `Chat` objects to a detached task. Future background processing must receive Sendable value snapshots only. |
| Item layout preparation and application | [ChatListItem.swift lines 541–568](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/ChatListUI/Sources/Node/ChatListItem.swift#L541-L568), `nodeConfiguredForParams` | Separate computation from application. In imimchat, first remove redundant presentation work; do not replace all rows with AsyncDisplayKit. |
| Transition application | [ChatListNode.swift line 3592](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/ChatListUI/Sources/Node/ChatListNode.swift#L3592) | Pass change sets and scroll constraints together. This is a later chat-scroll design reference, not an implemented fix. |
| Cached avatar plus later delivery | [AvatarNode.swift lines 766–777](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/AvatarNode/Sources/AvatarNode.swift#L766-L777), cached image / `loadSignal` | Keep Kingfisher's memory-first result and subsequent replacement. Telegram also has a synchronous-load option; do not claim its avatars never perform synchronous work. DirectMediaImageCache internals were not audited here. |
| Stable message changes | [PreparedChatHistoryViewTransition.swift lines 11–17](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/PreparedChatHistoryViewTransition.swift#L11-L17) | Later phase: keep message IDs and distinguish historical insertions from new messages. No encryption changes. |
| Stationary list offset | [ListView.swift lines 2123–2128](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/Display/Source/ListView.swift#L2123-L2128) | Later phase: explicit visible-item anchor when content changes; not an instruction to copy the custom ListView. |

## Pre-A1 findings (line references to the audited baseline)

1. `ChatsView.swift:21–24,39,52`: `conversations` is a computed property used for emptiness and iteration. Each invocation filters, sorts and maps all matching chats (`ChatsViewModel.swift:51–72`). These computations are definite; actual evaluation frequency and user-visible cost require a SwiftUI trace.
2. `ChatsView.swift:53`: each materialized row searches `chats.first(where:)` again. A complete traversal of N unique chats performs N(N+1)/2 ID comparisons in the synthetic fixture. LazyVStack means this is NOT proof that every frame materializes all rows.
3. `ChatsViewModel.swift:27` → `Date+ChatFormatting.swift:4–7`: each projected row creates a DateFormatter. The actual extension can be benchmarked independently; the proposed formatter reuse needs locale/timezone/date-boundary tests.
4. `AvatarImageLoader.swift:8,159–167,210–218`: memory miss falls back to synchronous disk data read and UIImage construction on MainActor. Actual pixel decode/render cost is unmeasured. This is a candidate cold-start/scroll risk, not a confirmed dropped-frame cause.
5. Positive existing behavior: `AvatarImageLoader.swift:57–60` uses stable user ID/path identity; `84–123` has asynchronous disk prewarm; `221–261` has request merging, visible priority, bounded downloads, downsampling and background decode; `264–291` rejects stale completions and replaces only matching views. Preserve these, do not build a second cache.

## Initial recommendation

First implement one transient presentation per body evaluation and carry the correct `Chat` reference with each row, retaining `chatId` identity, instead of an unconditional whole-table dictionary rebuild. Validate duplicate/missing IDs and all current interactions. Then separately address formatter allocation. Do not begin by rewriting avatar loading or the list container.

Implemented A1 on 2026-10-08: `ChatsView.swift:26` creates one transient `conversationRows` result, and the ForEach reads `row.chat`/`row.conversation` directly. `ChatsViewModel.swift:41–64` adds the ephemeral row type/projection, retaining domain identity and existing filter/sort/subtitle logic. No Telegram source was copied. DateFormatter and avatar work remain unchanged.

## A2 — reuse only the App's time-formatting machinery

The pinned Telegram source was rechecked on 2026-10-08. `ChatListItem.swift:2271–2291` reuses existing node layout closures and prior cached derived inputs; `ChatListItem.swift:2858–2875` illustrates checking cached-input compatibility before expensive derivation. These excerpts motivate reuse/invalidation discipline only, not a claim that Telegram uses imimchat's formatter design.

The subsequent A2 change independently reuses the App's two existing DateFormatter patterns in `Date+ChatFormatting.swift`. It retains fresh today/day selection, Foundation defaults and a locale/calendar/timezone context; invalidation and formatting share one short synchronous ownership boundary. No Telegram formatter, node, source/assets, services or new framework were copied/imported. This supersedes the earlier statement that the date helper is unchanged; avatar and persistence code remain untouched in A2.

Apple profiling source: [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/). Use SwiftUI + Time Profiler + Hangs/Hitches to determine whether body updates, layout or render work is responsible.

## A3 — avatar presentation reuse without changing cold-first-frame policy

Rechecked the pinned `AvatarNode.swift:766–777` cached-image / subsequent main-queue delivery excerpt. imimchat already implements the equivalent cache-first/replace-later policy using Kingfisher; A3 does not transplant Telegram's media cache or promise fully asynchronous cold rendering.

Actual-source Catalyst measurements identified repeated fallback-image drawing and per-byte SHA256 hexadecimal formatting. A3 independently reuses only generated fallback bitmaps in a bounded MainActor NSCache, keyed by initial/group/size/renderer scale/appearance traits/language. It replaces String(format:) hex encoding with byte lookup without changing SHA256 or persisted digest text. Peer images remain solely in the existing Kingfisher cache. The synchronous disk first-frame path, prefetch scheduler, stale guards, network request semantics and public APIs are unchanged. No Telegram source/assets were copied.

## B1 — bounded scroll-intent policy, 2026-10-09

Reverified the clean local official reference at the same pinned commit.
[PreparedChatHistoryViewTransition.swift lines 84–110](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Sources/PreparedChatHistoryViewTransition.swift#L84-L110)
separates initial/interactive/reload reasons and stationary ranges from scroll
targets. [ListView.swift lines 2123–2128](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/Display/Source/ListView.swift#L2123-L2128)
applies a stationary offset separately from explicit position correction.
These are mechanism references only, not proof that Telegram implements this
App's callback-ticket policy or that its entire scroll engine was audited.

imimchat retains SwiftUI ScrollViewReader and its existing rows. B1 independently
coalesces delayed bottom-follow requests and invalidates them when user scroll
starts/view disappears; it does not copy Telegram's list engine or implement
historical-insertion offset preservation.

Apple references: [native scroll phases](https://developer.apple.com/documentation/swiftui/view/onscrollphasechange(_:)-1k12m)
and [Reduce Motion environment](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion).
Installed Xcode SDK interfaces confirm iOS 18 availability; iOS 17 keeps a
simultaneous touch-drag fallback with its documented inertia limitation.

## D1 / B2 — thumbnails and local voice updates, 2026-10-09

Official checkout remains pinned at `6ad963e5b62d354da79040f388ae2b9132fb17b8`.
Inspected [DirectMediaImageCache.swift:291–315](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/DirectMediaImageCache/Sources/DirectMediaImageCache.swift#L291-L315):
it draws a size-specific aspect-filled representation and disposes fetch/data
subscriptions. This excerpt uses UIImage plus DrawingContext and stores to its
media box; it does not show ImageIO downsampling. imimchat independently uses
ImageIO on a serial actor, passes only thumbnail CGImage back to MainActor, and
creates no persistent plaintext thumbnail cache. The mechanism reference is
bounded display-size work plus cancellation, not identical code/cache design.

Inspected [ChatMessageInteractiveFileNode.swift:148–178](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift#L148-L178),
[275–280](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift#L275-L280)
and [1431–1462](https://github.com/TelegramMessenger/Telegram-iOS/blob/6ad963e5b62d354da79040f388ae2b9132fb17b8/submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift#L1431-L1462):
playback status/timer and audio-level subscriptions are node-local, delivered on
the main queue; visibility stops blob animation, deinit disposes subscriptions.
imimchat retains Combine/SwiftUI and its existing audio manager: start/stop/errors
update the screen, recording meters update an overlay child, only the matching
voice presentation publishes playback progress. Its existing TimelineView now
drives a finite phase while active and pauses for stop/Reduce Motion, without
retaining a repeatForever animation. It does not import Telegram nodes/timers
or claim the same renderer or visibility implementation.

Apple sources: [iOS Memory Deep Dive — ImageIO downsampling](https://developer.apple.com/videos/play/wwdc2018/416/)
and [immediate image source cache/decode option](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately).
Only the excerpts above were inspected; no Telegram source/assets were copied
and no Telegram build scripts/services were run.
