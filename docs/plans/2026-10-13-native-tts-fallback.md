# Free native TTS fallback

> **Historical record (reviewed 2026-10-21).** Historical Edge-primary/Piper-suspended fallback campaign, superseded by current provider policy. Keep its original stop-budget wording and local-only delivery limits; infer no current failure threshold or completed PR. Use [execution policy](../agents/execution-policy.md) for current scope, guarded builds and Simulator quarantine, and [runtime navigation](../agents/runtime-navigation.md) for architecture; old commands and authorizations are retained only as evidence.

Task APP-20261013-04. Edge remains primary; installed platform speech is the
temporary free fallback for isolated failed segments. No paid providers, implicit downloads, Piper activation,
reader geometry changes, or physical-device benchmarks.

Discovery ownership: Rust specialist owns worker/native speech encoding/tests;
Apple specialist owns Swift provider/adapter/preferences/notice/native tests;
Android specialist owns Kotlin/native JNI adapter/Dart notice/tests. Root owns
shared C ABI/session configuration, integration review and serialized checks.

Add a per-session native speech callback, with borrowed cancellation callback
and WAV output path. Platform adapters generate speech only. Rust divides text
into a short initial segment and bounded later segments, validates and encodes
MP3, delivers ordered chunks and atomically publishes chapters. Never restart
the full chapter after some audio was emitted. User correction: local/Siri speech
is temporary for isolated failed segments because it misreads text. Retry Edge
on each next segment; stop after two consecutive Edge segment failures rather
than switching the book to local speech. Use a distinct v2 cache policy so earlier
book-wide native caches cannot satisfy this request. Cancellation and stale playback windows
must fail/stop before fallback or persistence. Missing exact local language
must be actionable and must not substitute another language or download a voice.

Affected seams: converter-core worker/platform_tts/audio encoding, converter-ffi
C/JNI bridge, Swift Conversion services/Settings/notice, Android platform TTS,
and regression tests beside each runtime. Retain old ABI behavior when no
platform callback is installed. Cache includes fallback policy and actual provider.

Risks: thread/MainActor deadlock, asynchronous speech completion/cancellation,
WAV variants, duplicated chunks after Edge partial failure, missing local voices,
cross-provider cache reuse, voice-change notice delivery and SwiftPM source list.

Verify controlled Edge failure and cancellation in Rust; real native speech WAV
and final MP3 through current Rust FFI in macOS and exact iPhone SE 1st generation
/ iOS15.5 with Xcode16.4; install/launch both apps serially. Android JNI must
compile for actual arm64 target, Kotlin/Dart regressions and APK build; record
no connected Android device rather than claiming runtime playback. Reuse valid
artifacts and the existing shared heavy-job lease, leave exact SE app open.

The worktree contains substantial prerequisite streaming/Edge work on an
existing feature branch plus unrelated changes. A dedicated feature branch
retains that current state to avoid discarding dependencies; its current HEAD
is 18716268ce, while local master is 353cadd043. No unrelated changes may be
included in delivery. Review owned edits separately from pre-existing diffs.

## Verified evidence

- `mise run native-tts:rust:test`: 34 tests passed (2 PCM/segmentation,
  30 worker regressions, 2 real C callback tests); current debug FFI built.
- Opt-in Foundation runtime suite: 36 passed, no skips. Actual installed
  Portuguese speech, cancellation, forced system MP3, real failed Edge request
  fallback, and successful primary live Edge conversions exercised.
- Native macOS suite: 13 passed, no skips, including actual player time advancing
  on the first MP3 chunk while the conversion is still blocked before later
  chunks. Result: `Test-EpubToMp3Mac-2026.10.13_17-58-01--0300.xcresult`.
- Current optimized host FFI and native macOS app built; `mac:run` installed
  and launched the actual app. Own-window screenshot:
  `/tmp/epubtomp3-native-fallback-macos.png`. App stopped and verified exited
  before switching to iOS.
- `mise run preflight` and `git diff --check` passed. Python/Ruff and broad
  CI gates remain deferred to CI; no CI/PR monitoring performed.
- Actual Android arm64 NDK/JNI release build passed; installed source library
  SHA256 `a512d95e28248d5172b293cbc1aab5ef8466539f5f12ef4b80e43a2f1eb95de2`.
  `native-tts:android:test`: 17 Flutter and 7 Kotlin/JVM tests passed, no skips.
  `flutter:analyze`: no issues after fixing four new missing-braces diagnostics.
  `flutter:build-apk-debug`: passed, 179 MiB APK. Source equals Gradle's merged
  JNI artifact; packaged bytes equal Gradle's stripped artifact (SHA256
  `cc36498b93826a305afe96eeae56613263edc8a6a4e9698aee59cd93efa2193d`).
- Fresh iOS Simulator FFI debug build passed without Piper.

Initial native failures were traced to a truncated test PNG, repaired using
ImageIO without weakening production EPUB validation. A concurrent test-source
edit interrupted one build; subsequent native builds use frozen sources.

Android's incremental slice is tracked as APP-20261013-04-ANDROID-STREAM:
request-scoped atomic JNI chunk files/events, listener readiness before conversion,
and one growing per-chapter player source. Final method result closes the source
after queued chunks drain; exact-request cancellation/window changes reject late
events. Completion preserves source identity and chapter navigation. Unknown-length
initial responses disable byte ranges; seeks needing unavailable bytes await
completion instead of declaring EOF or rebuilding the queue. Source/channel/window
tests and fresh JNI/APK artifacts are required after implementation.
No connected Android device is available; compile/unit evidence cannot establish
weak-phone latency, battery, thermals or actual Android engine behavior.

The first exact iOS run executed 18 tests: WAV, MP3, cancellation, actual Edge
playback and native progressive playback passed. Only two assertions in the same
notice test failed because its inspection happened after the eight-second notice
expired. Cold Simulator native synthesis took about 14 seconds for the initial
180-character utterance; the multi-chunk native playback test took 36.639 seconds
for approximately 500 characters. This is Simulator evidence, not a physical
phone benchmark. It motivates native-only subdivision (60 characters initially,
240 later) while preserving Edge's larger requests. Recheck ordered mixed-provider
delivery and all affected native paths with current artifacts after this change.

## Final local verification

User correction is implemented: Edge is retried on every segment; the third
consecutive failed Edge segment stops conversion before more local speech.
Successful Edge resets the counter. Old `v1` fallback caches are excluded by
the `edge+system-v2` request identity. System-only options remain hidden test
fixtures; product choices offer Edge.

- Rust/FFI: 39 passed (2 platform, 33 worker, 2 C callback, 2 JNI chunk-store).
  Tests include recovery after isolated failure, persistent outage without a
  published partial chapter, actual receipt/cache behavior and atomic chunks.
- Current host, Android arm64, iOS arm64 device and exact Simulator FFI builds
  passed without enabling the Piper runtime.
- Native macOS: 13 passed, no skips, result
  `Test-EpubToMp3Mac-2026.10.13_18-44-32--0300.xcresult`.
  Strict live Edge playback additionally passed 1/1, no skips, result
  `Test-EpubToMp3Mac-2026.10.13_19-07-47--0300.xcresult`.
- Exact SE/iOS15.5: 18 passed, no skips, result
  `Test-EpubToMp3-2026.10.13_18-47-05--0300.xcresult`.
  Strict actual Listen additionally passed 1/1, no skips, result
  `Test-EpubToMp3-2026.10.13_18-55-22--0300.xcresult`.
  Strict cases reject both system-provider progress and direct speech transport
  before first audio and after final conversion; actual player time advances.
- Android: 55 focused Flutter tests passed; 7 Kotlin/JVM tests passed earlier
  and the final Gradle task reused those unchanged results. Static analysis is
  clean. Final debug APK built (206 MiB), with current JNI source matching the
  merged artifact and packaged bytes matching the stripped artifact. Packaged
  JNI SHA256: `56e2c5171e2e1690e6df05240ef49f9f457f6d27e27433e0aa0f5b0c5c186053`.
  Tests cover early bytes, ranges after completion, cancellation during listener
  handshake, queue identity, cached Listen startup, stale generations, exact
  request cancellation and preservation of already queued immutable files.
- User heard deliberate Portuguese native test fixtures through this Mac's
  speakers; the active executable was the iOS Simulator test host, not a CLI
  narrator. GUI is now visible. The normal app's seeded Lord of the Rings EPUB
  declares language `en`; reading state was preserved. Only the exact SE app is
  left open (PID 59198); screenshot `/tmp/epubtomp3-native-fallback-ios15.png`.
- Final `preflight` and whitespace checks pass; owned Rust and Dart files are
  formatted. Local Python/Ruff tests and CI/PR monitoring were not run.

Android incremental playback is implemented, but actual device playback,
weak-phone latency, energy and thermals remain unverified without an attached
Android device. Nonzero seeks in an incomplete growing chapter wait for its
completion. iOS arm64 compilation is not physical iPhone playback evidence.

Changes remain local on `feature/native-tts-fallback`: no commit/push was made
because pre-existing prerequisites and unrelated reader/Piper changes share
the edited files and no clean task-only baseline was available. Parent task and
Android runtime acceptance remain in Verification rather than marked Done.
