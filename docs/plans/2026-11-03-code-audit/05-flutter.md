# Phase 5: Flutter audit playbook

Status: planned. Source and task inspection informed this document; no Flutter
analysis, tests, builds, device journey or remote execution ran for this plan.
Start after the Swift/Xcode and Rust phases have resolved the prerequisites for
the selected slice. See the [audit overview](../2026-11-03-complete-code-audit.md).

## Scope, ownership and observed starting points

- Flutter owns Linux, Windows and Android; Apple uses the native Swift client.
  [main.dart](../../../flutter_app/lib/main.dart) registers Android and desktop
  embedded converters before providers resolve them, and initializes the desktop
  audio backend before constructing playback services.
- [providers.dart](../../../flutter_app/lib/state/providers.dart) selects
  `ConverterMode.embedded`. HTTP-facing providers and a compatibility adapter still
  exist. Their presence does not prove a backend dependency in an active journey.
- [DesktopEmbeddedConverter](../../../flutter_app/lib/services/desktop_embedded_converter.dart)
  loads the FFI library, queues worker operations and tracks native job controls
  by output path. Android uses platform channels with streaming subscriptions.
- [pubspec.yaml](../../../flutter_app/pubspec.yaml) includes Python compatibility
  assets and generated localization. Neither category is automatically removable.
- The real Linux decoder test is opt-in. Real FFI tests require explicit library
  and fixture inputs; ordinary green tests may have skipped these boundaries.

These are source observations, not confirmed defects or runtime acceptance.
The execution owner must recheck them against the revision actually tested.
Linux/Android builds, tests and artifacts belong on Arch. Android is paused until
the user explicitly resumes it; Windows requires its own compatible environment.
This document authorizes no remote messages, model downloads or device actions.
Follow [execution policy](../../agents/execution-policy.md) and
[Mac/Arch coordination](../../agents/mac-arch-collaboration.md).

## Step 1: establish coverage and a platform baseline

1. Record commit, dirty paths, Flutter/Dart versions, lockfile identity, native FFI
   provenance and the selected host. Preserve existing libraries and user data.
2. Inventory `lib/`, `test/`, `integration_test/`, Android Kotlin/JNI integration,
   desktop runners, CMake, localization, assets and packaging workflows. Distinguish
   owned code, generated output, third-party inputs and compatibility code.
3. Trace each registered runtime from startup through providers to an actual
   conversion/playback call. Record symbols, channels, worker boundaries and
   persisted keys. Compare contracts with [CONTEXT.md](../../../CONTEXT.md) and
   [MIRROR-MAP.md](../../../flutter_app/MIRROR-MAP.md); old mirror comments are not
   evidence that current behavior matches Swift.
4. For the selected platform, record a known-good import/open/play/cancel/relaunch
   journey using approved fixtures and existing installed models. If execution
   is unavailable or paused, mark that platform pending before proposing a fix.
5. Create finding records with trigger, observed/expected result, source path,
   reproduction, severity, identity at risk, owner, smallest patch and acceptance.
   Keep hypotheses separate from reproduced bugs and optional improvements.

## Step 2: audit composition, lifetime and native boundaries

1. Start with startup registration and `providers.dart`; enumerate subscriptions,
   timers, notifiers and async initialization. Trace who creates and disposes each
   resource, including provider replacement and widget updates.
2. Inspect [AsyncLoadGuard](../../../flutter_app/lib/services/async_load_guard.dart),
   `book_open_screen.dart`, `sse_subscription_lifecycle.dart` and the conversion
   coordinator. Test A-to-B-to-A navigation while earlier work completes; mounted
   state alone does not establish correct book or request identity.
3. Trace desktop ownership through `desktop_ffi_bindings.dart`,
   `desktop_conversion_worker.dart` and `desktop_listening_schedule.dart`. Check
   allocation/free pairs, worker exceptions, native control lifetime, queue
   recovery, duplicate output ownership and cancellation before/during completion.
4. Trace Android's `android_converter_channel.dart` into
   `FlutterConversionChannels.kt`, `NativeConversionAwait.kt` and
   `ChannelReplies.kt` under the app's Kotlin package. Check exactly-once replies,
   channel payload validation, stream readiness, late events and activity/service
   lifecycle. This is source review while Android remains paused.
5. Extend the smallest relevant existing suite: `async_load_guard_test.dart`,
   `providers_reader_test.dart`, `sse_subscription_cleanup_test.dart`,
   `embedded_converter_test.dart`, `desktop_conversion_worker_test.dart` or the
   owning Kotlin test. A mocked channel does not verify native loading or ABI.

## Step 3: audit import, identity and retained storage

1. Follow [LibraryStore](../../../flutter_app/lib/services/library_store.dart),
   `incoming_document_service.dart`, `epub_metadata_reader.dart` and Android's
   `IncomingDocumentIntake.kt`/`IncomingDocumentUriPolicy.kt`. Distinguish original
   documents, temporary picker files, durable imports, reader caches and audio.
2. Exercise same-content reimport, same-name/different-content import, moved or
   missing input, extensionless documents, malformed metadata and persistence
   failure. Verify that an error preserves the previous usable library entry.
3. Inspect `audiobook_downloads.dart`, `download_manager.dart`,
   `protected_audio_storage_guard.dart`, `offline_cache_eviction.dart` and
   `rebuildable_cache_policy.dart`. Trace every deletion and write boundary,
   including symlinks/path traversal, partial files and available-space failures.
4. Confirm that completed offline listening audio survives automatic maintenance,
   app restart and interrupted conversion. Only the listener's explicit removal
   deletes retained audio; a cache cleanup must not cross into that collection.
5. Extend `library_store_test.dart`, `incoming_document_service_test.dart`,
   `download_path_boundary_test.dart`, `protected_audio_storage_guard_test.dart`,
   `offline_cache_eviction_test.dart` and `resume_store_integration_test.dart` as
   appropriate. Use isolated temporary roots, never a user's library as a fixture.

## Step 4: audit reader and navigation

1. Trace direct opening through `book_open_screen.dart`, `book_content_session.dart`,
   `book_reader_body.dart`, `views/reader_view.dart`, `reader_paginated_layout.dart`
   and `pdf_reader_screen.dart`. Opening a book must not synthesize or autoplay.
2. Compare rendered EPUB/PDF against known source structure: chapter order,
   hierarchy, anchors, images, fonts, links and missing-resource fallback. Verify
   TOC navigation, search and bookmarks against stable source identity.
3. Exercise full-line visibility, chrome changes, font/scale changes, narrow
   windows, orientation and chapter boundaries. Preserve the reading anchor and
   avoid flashes of the previous chapter while async content loads.
4. Verify restart restoration separately from within-session navigation. Include
   deleted chapters, stale stored positions and rapid switching between books.
5. Extend `book_open_screen_test.dart`, `reader_html_render_test.dart`,
   `reader_chapter_cross_flicker_test.dart`, `toc_navigation_coordinator_test.dart`,
   `resume_restoration_guard_test.dart`, `pdf_reader_screen_test.dart` and
   [reader_view_fit_test.dart](../../../flutter_app/test/views/reader_view_fit_test.dart).
   Widget geometry checks supplement the actual supported-platform app journey.

## Step 5: audit listening, conversion and background work

1. Trace `audio_player_service.dart`, `audio_playback_state.dart`,
   `playback_snapshot.dart`, `background_audio_handler.dart` and the mini/full
   players. Confirm they distinguish requested playback from decoder readiness,
   audible progress, buffering, pause, completion and failure.
2. Review `rust_playback_conversion.dart`, `reader_playback_startup.dart`,
   `growing_chapter_audio_source.dart` and `playback_chapter_window.dart`. Exercise
   first audio, partial streams, chapter replacement, out-of-order delivery,
   cancellation and seeks to audio that is not yet available.
3. Follow manual conversion through `convert_screen.dart`,
   `conversion_job_coordinator.dart`, `local_conversion_store.dart` and background
   scheduling. Verify inclusive ranges, option forwarding, progress, terminal
   persistence and recovery after relaunch. Manual conversion must not autoplay.
4. Inspect `tts_preferences.dart`, `desktop_tts_model_adapter.dart`,
   `android_speech_fallback.dart` and `platform_voice_notice.dart`. Preserve Piper
   Faber as primary, identify actual fallback voice, keep explicit job selections,
   retry Piper only at bounded recovery points, and require consent for Edge.
5. Extend `audio_playback_state_test.dart`, `segment_queue_identity_test.dart`,
   `rust_playback_conversion_test.dart`, `manual_conversion_output_test.dart`,
   `background_conversion_lifecycle_test.dart`, `playback_resume_persistence_test.dart`
   and `platform_voice_notice_test.dart` according to the failing seam.
6. Reproduce affected playback on the real decoder and conversion on the registered
   native adapter. Do not infer audibility from a Play icon, mock, timer or
   successful method-channel reply. Preserve privacy when retaining audio/logs.

## Step 6: audit quality, packaging and removable content

1. Run the analyzer on the owning host and classify findings before changing
   [analysis_options.yaml](../../../flutter_app/analysis_options.yaml). Review
   warning exclusions and generated annotations; do not suppress findings just
   to obtain a green result or apply repository-wide formatting without need.
2. Check screen-reader labels, keyboard/focus navigation on desktop, text scaling,
   contrast, error recovery and EN/PT/ES parity. Edit `.arb` sources and regenerate
   through the project route rather than manually patching generated Dart files.
3. Inspect `latency_observation.dart`, logs and error messages for raw book text,
   full personal paths or unnecessary identifiers; extend
   `latency_observation_privacy_test.dart` where the behavior changes.
4. Review [desktop packaging](../../../flutter_app/cmake/README.md),
   `converter_runtime.cmake`, `stage_converter_runtime.cmake`, Android Gradle and
   platform runners. Verify packaged FFI, ONNX libraries, phonemizer data, target
   architecture and relocatable paths using the resulting platform bundle.
5. Trace `python_bridge.dart`, `api_client.dart`, compatibility assets and related
   dependencies through callers, tests, pubspec, native packaging and CI. Propose
   exact removals with bundle-size impact, remaining consumers and rollback;
   obtain user confirmation for relevant removal before applying it.
6. Measure any performance proposal with comparable fixtures, voice, cache state,
   build mode and device. Record UI responsiveness, first audible audio, memory
   and package size separately. Lower build time does not prove faster playback.

## Step 7: execute and validate one selected finding

1. Choose one reproduced defect or evidence-backed improvement. Define its public
   behavior, affected platforms and independent expected result before editing.
2. Establish a failing runtime regression when feasible; record any unavailable
   platform or reason a red baseline cannot be obtained. Then make the smallest
   complete change at the owning seam and rerun the original reproduction.
3. Use these existing entry points only after inspecting their current definitions
   and obtaining any missing execution/platform authorization:

| Entry point | Evidence and limits |
| --- | --- |
| `mise run flutter:analyze` | Dart type/lint findings; not runtime behavior. |
| `mise run flutter:test -- test/<selected_test>.dart` | Focused unit/widget regression; identify mocks and skipped cases. |
| `mise run flutter:test -- --dart-define=EPUB2MP3_NATIVE_DECODER=true test/linux_audio_backend_integration_test.dart` | Opt-in Linux decoder journey on Arch; emits a generated tone, no model download. |
| `test/desktop_listening_ffi_integration_test.dart` via `flutter:test` | Real FFI only with explicit `TTS_TEST_FFI_LIBRARY` and, for conversion, `TTS_TEST_EPUB`; conversion selects `engine=system` and requires an available installed system speech backend. Record skips; do not install a backend implicitly. |
| `mise exec -- cmake -P flutter_app/cmake/stage_converter_runtime_test.cmake` | Packaging fixture only; no proof of real binary loadability. It deletes the fixed `.reports/tts-preferences/desktop-packaging-fixture` directory at start/end: verify exclusive disposable ownership and preserve any prior evidence before execution. |
| `mise run flutter:build-linux` / `flutter:build-windows` | Platform packaging; CMake can compile Rust/Piper dependencies. |
| `mise run native-tts:android:test` / `flutter:build-apk-debug` | Android/Gradle/native work on Arch, blocked until Android is resumed. |

4. Do not use `flutter:run` as a general desktop inspection command: its current
   implementation selects Android and can start an emulator. Do not invoke
   `android:bootstrap-python` to prepare the embedded production runtime.
5. For affected UI, exercise the real app on the supported authorized target.
   Retain command, SHA, dirty state, binary identity, pass/fail/skip counts and
   observed behavior. Windows and Android acceptance remain independent of Linux.
6. Review the complete scoped diff, documentation and evidence. Deliver one PR per
   coherent correction and follow the [delivery workflow](../../agent-workflow.md).
   Resolve or explicitly defer blocked acceptance before starting dependent work.

## Phase exit and confirmation points

Every inventoried surface has a reviewed status or an explicit exclusion with an
owner and reason. Each finding is fixed with evidence, deliberately deferred, or
blocked with the missing condition named; none is silently marked complete.
Confirm new screens, removed functionality, compatibility/platform changes,
relevant deletions and user-data migrations before execution. Request model or
runtime installation and new benchmark/device scope separately when needed.
Report platform results independently and pass unresolved items to phase 6.
