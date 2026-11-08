# Build 81 upload receipt

- Marketing version / build: **1.0 / 81**.
- Published source commit: `420483e9ba7a8cb391f497a2e6c29078d76060c5`.
- Frozen release source manifest SHA-256: `66fd21501c0c7714cb07e623e0d9c701618c63e664537f558917b970884714a5`.
- Uploaded IPA SHA-256: `b74222dd9b2ac82fe94f73f62544aff920acb7c46bd16c813bb2bfc5c7bde206`.
- Release archive: succeeded. All seven scoped regression suites passed; selected-message retry and the published cache/concurrency suite were rerun after the archive compatibility correction.
- Main app and notification extension both identify version 1.0 / 81. Strict signature verification passed on the re-signed distribution IPA, with `get-task-allow=false`.
- Archived symbols match the embedded TRTC, TXFFmpeg and TXSoundTouch framework UUIDs.
- Existing encryption declaration is unchanged for both bundles.
- Apple upload completed at 2026-11-09 01:53:12 +08:00. `xcodebuild -exportArchive` exited 0 with `Uploaded package is processing.`, `Upload succeeded.` and `** EXPORT SUCCEEDED **`.
- **Last verified Apple state: uploaded and processing.** App Store Connect web login has expired and the configured API private key is unavailable. Build processing completion, internal tester availability, and saving bilingual What to Test notes have not been verified.
- No formal App Store review submission or phone installation was performed. No backend runtime/data change was made.
- Original working tree status, tracked edits and index were compared with their pre-release backups and preserved.

See [the test plan](release81-20261109.md). Real iOS-to-iOS exchange, multi-device fan-out, group exchange and APNs acceptance remain pending. Lost historical keys are not recovered by this release.
