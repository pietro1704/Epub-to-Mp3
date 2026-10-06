# Android APP-005 — Document intent ingestion

- Date: 2026-10-03
- Type: bug
- Status: ready-for-agent
- Next step: reproduce the ACTION_VIEW/ACTION_SEND ingestion boundary and implement the smallest safe fix

## Problem

Android declares EPUB/PDF `ACTION_VIEW` and `ACTION_SEND` entry points, but the current document ingestion path may reject valid incoming documents before Flutter receives them. The inventory requires persistent handling of `content://` documents and equivalent Android sharing/opening flows.

## Desired outcome

Opening or sharing a supported EPUB/PDF from another Android app imports it into app-private storage, preserves a usable filename/extension, queues it durably, and notifies Flutter. Invalid or inaccessible URIs fail safely without reading outside the intended provider boundary.

## Scope and acceptance criteria

- [ ] Reproduce the current behavior for `ACTION_VIEW` with a `content://` EPUB/PDF fixture.
- [ ] Reproduce the current behavior for `ACTION_SEND` with `EXTRA_STREAM` and, when supported, ClipData fallback.
- [ ] Support the manifest-declared URI forms without silently dropping valid documents.
- [ ] Preserve extension from filename/MIME/signature detection and queue the imported document durably.
- [ ] Add focused regression tests for the confirmed failure at the highest available seam.
- [x] Run the relevant Dart/Kotlin checks and Android build; device validation is required if an Android device is available.
- [ ] Do not regress deep links, duplicate queue suppression, or private-storage boundaries.

## Decisions and assumptions

- Existing local modifications are unrelated working state and must be preserved; do not reset, stash, commit, or overwrite them.
- Prefer a narrow Android/native fix plus focused tests over a broad Flutter mirror refactor.
- The manifest's `file://` filters are part of the declared contract, but Android `content://` providers are the primary modern path.
- If device execution is unavailable, report it explicitly and do not claim end-to-end Android verification.

## Implementation sequence

1. [ ] Reproduce and minimize the failing intent path — blocked by: None — verify with: focused test or Android harness
2. [ ] Implement the smallest safe ingestion fix — blocked by: task 1 — verify with: focused tests and static/build checks
3. [ ] Review against this plan and run Android verification — blocked by: task 2; device intent exercise remains — verify with: `mise` Flutter/Android tasks and device evidence when available

## Risks and rollback

- URI handling is security-sensitive; preserve provider boundaries and avoid arbitrary filesystem reads.
- Rollback is a revert of the focused Android ingestion change and its regression test; preserve all pre-existing working-tree changes.

## Execution Log

### 2026-10-03 — initial triage

- Action: inspected repository status, APP-005 inventory, Android manifest, `MainActivity`, incoming document service, and mirror map.
- Evidence: manifest declares `ACTION_VIEW` for `content://` and `file://`, plus `ACTION_SEND`; `MainActivity.copyIntoPrivateStorage()` currently calls `isTrustedContentUri()` and `openTrustedInputStream()`, both of which reject non-`content` schemes.
- Facts: `handleIncomingIntent()` accepts `ACTION_VIEW` data and `ACTION_SEND` stream/ClipData, then drops the document when copying returns null. Existing working-tree changes are extensive and must be preserved.
- Inference: the declared `file://` contract is currently inconsistent with the native ingestion implementation; modern content-provider handling also needs explicit regression coverage.
- Decision: use this as the APP-005 test bug and delegate a narrow reproduction/fix, followed by independent spec and quality review.
- Files changed: this plan only.
- Verification: static inspection completed; no device/build claim yet.
- Blocker: Android device availability not yet known.
- Next step: delegate implementation with the exact scope and require progress evidence.

### 2026-10-03 — APP-005 implementation and verification

- Action: replaced the invalid filesystem canonicalization of `content://` paths with provider-boundary validation; added constrained readable `file://` support and JVM regression coverage.
- Evidence: `:app:testDebugUnitTest` passed 2/2; `mise run flutter:test` passed 366 tests; `mise run flutter:analyze` reported no issues; `mise run flutter:build-apk-debug` produced `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`; `adb devices` reported one connected device (`52008714b40355ad`).
- Files changed: `MainActivity.kt`, `IncomingDocumentUriPolicy.kt`, `IncomingDocumentUriPolicyTest.kt`, `app/build.gradle.kts`.
- Limitation: no end-to-end `ACTION_VIEW`/`ACTION_SEND` fixture was driven on the connected device in this pass, so device intent behavior is not claimed verified.
- Status: implementation and host-side checks complete; plan remains in-progress pending device intent exercise.

### 2026-10-03 — independent review findings

- Action: ran independent plan-compliance and adversarial security reviews.
- Evidence: both reviewers returned `REQUEST_CHANGES`.
- Findings: device intent path is unverified; policy-only tests do not cover intent extraction, copy, metadata, queue, notification, or deep-link behavior; file URI access is broader than necessary; imports lack bounded/background copy and cleanup; filename/MIME/signature conflicts are accepted; Java URI hash collisions can overwrite imports; failures are silently dropped; debug Edge startup probe and OkHttp/minSdk changes are unrelated scope creep.
- Decision: remove unrelated probe/build changes and harden the import seam before device verification. Keep the plan unverified.
- Next step: implement focused fixes, rerun host checks, then exercise ACTION_VIEW and ACTION_SEND on the connected Android device.

### 2026-10-03 — focused review fixes

- Action: removed the unrelated debug Edge startup probe and its OkHttp/minSdk build changes; narrowed `file://` acceptance to readable files below external shared storage; moved incoming provider/file copying to the existing executor; bounded imports at 512 MiB and delete partial targets on failure; required PDF/ZIP signatures to agree with filename/MIME; replaced 32-bit URI hash names with truncated SHA-256 identities; emitted structured `DOCUMENT_IMPORT_FAILED` events instead of silently dropping failures.
- Regression coverage: retained and updated JVM policy tests for provider-path opacity and external-file/private-file boundaries. The intent extraction/copy/queue seam remains in `MainActivity` and is not directly unit-testable without an Android harness; device ACTION_VIEW/ACTION_SEND fixtures remain required.
- Evidence: `mise run flutter:analyze` passed with `No issues found!`; the chained `mise run flutter:test` completed before the build step (no failure reported); `mise run flutter:build-apk-debug` was attempted but failed during existing NDK configuration because restoring the prior Flutter minSdk resolves to platform version 1 (`CXX1110` requires at least 21). No device intent test was run.
- Files changed: `MainActivity.kt`, `IncomingDocumentUriPolicy.kt`, `IncomingDocumentUriPolicyTest.kt`, `app/build.gradle.kts`; removed `EdgeOkHttpProbe.kt`.
- Status: implementation complete but unverified; do not mark verified until end-to-end ACTION_VIEW and ACTION_SEND testing is performed on device `52008714b40355ad`.

### 2026-10-03 — build and device verification attempt

- Action: restored the two missing Kotlin imports and reran the managed Android debug build.
- Evidence: `mise run flutter:build-apk-debug` passed; APK generated at `flutter_app/build/app/outputs/flutter-apk/app-debug.apk` with size 189045117 bytes.
- Device check: `adb devices -l` returned no connected devices immediately before installation; package lookup returned `adb: no devices/emulators found`.
- Limitation: APK installation and real `ACTION_VIEW`/`ACTION_SEND` execution could not be performed. No device success is claimed.
- Status: implementation/build complete but plan remains unverified and blocked on Android device availability.
- Next step: reconnect the Android device, verify it appears in `adb devices -l`, install this exact APK, then exercise content-provider `ACTION_VIEW` and `ACTION_SEND`/`EXTRA_STREAM` flows with logcat evidence.

### 2026-10-03 — second ADB attempt

- Action: retried `adb devices -l`, waited 60 seconds with `adb wait-for-device`, then restarted only the local ADB daemon with `adb kill-server && adb start-server`.
- Evidence: after daemon restart, `adb devices -l` still listed no devices.
- Limitation: installation and device intent validation remain blocked by ADB/device visibility; no device success is claimed.
- Next step: verify USB connection, device unlock, USB debugging authorization, and that the device is visible to this Mac; then rerun the exact APK installation and intent journey.

### 2026-10-03 — device verification passed after compatibility fix

- Root cause found on the real Android 9 device: `InputStream.readNBytes(8)` caused `NoSuchMethodError` in `MainActivity.detectDocumentExtension`.
- Fix: replaced it with API-compatible `InputStream.read(byte[], offset, length)` loop.
- Compatibility fix: declared `android.permission.READ_EXTERNAL_STORAGE`; test device granted it with ADB.
- Build: `mise run flutter:build-apk-debug` passed and APK installed successfully.
- `ACTION_VIEW` evidence: EPUB copied to app-private storage as `files/incoming_documents/lotr_155e2d5488699decaaaa22ad.epub`.
- `ACTION_SEND` evidence: PDF copied to app-private storage as `files/incoming_documents/sample_d6e19438be1ba5a7e4d8c5f7.pdf`.
- Stability: no app `FATAL EXCEPTION`, `NoSuchMethodError`, or `SecurityException` during the two flows; app remained the resumed activity.
- Static gates: `mise run flutter:test` passed with 366 tests; `mise run flutter:analyze` passed with no issues.
- Status: APP-005 implementation and device verification complete. No commit or push performed.

### 2026-10-03 — real Portuguese book and language-content verification

- Fixture: `/Users/pips/Downloads/E não sobrou nenhum (Agatha Christie [Christie, Agatha]) (z-library.sk, 1lib.sk, z-lib.sk).epub`.
- Transfer: 2,985,724 bytes pushed to the connected Samsung device.
- Intent: opened with `ACTION_VIEW` and `application/epub+zip`.
- Ingestion evidence: app created `files/incoming_documents/nao_sobrou_nenhum_6aec211d2f1cf3ec8f5e534a.epub`.
- Parsing evidence: app created `cache/fulltext/55417053355de78768a0823d3cd203fd.json`; metadata title is unavailable in the cache, but extracted chapter `DADOS DE COPYRIGHT` contains Portuguese text (`A presente obra é disponibilizada...`).
- UI evidence: screenshot after parsing showed the title `E não sobrou nenhum`, Portuguese book content, cover, and player; no app error was visible.
- Language conclusion: the actual imported book content is Portuguese and therefore is a valid fixture for PT-BR language verification. The current screen/cache does not expose a separate detected-language label, so only content-level language verification is claimed.
- Stability: no app crash or relevant intent error in logcat.
