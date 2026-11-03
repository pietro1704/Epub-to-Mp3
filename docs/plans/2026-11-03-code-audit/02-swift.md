# Phase 2 — Native Swift audit

Status: planned; source and test entry points were inspected to prepare this
playbook. No complete Swift audit, native build, test run or device journey is
claimed. Follow the [master plan](../2026-11-03-complete-code-audit.md).

## Scope, prerequisites and observed structure

Start after phase 1's required scope is accepted and integrated. Review all owned
Swift source, tests, resources and target membership, including UIKit, AppKit,
widgets, the share extension and `tools/DeviceWorkflow`. Track generated and
third-party files as explicit ownership exclusions; inspect their integration.

Read [execution policy](../../agents/execution-policy.md),
[coding standards](../../../CODING_STANDARDS.md),
[domain contracts](../../../CONTEXT.md), and
[runtime navigation](../../agents/runtime-navigation.md) at the execution SHA.
For reader work also read the [native contract](../../../ios/EpubToMp3/AGENTS.md),
[reader skill](../../../.agents/skills/native-reader-regression/SKILL.md), and
the [viewport](../../adr/2026-08-14-reader-viewport-transition.md),
[pagination](../../adr/2026-08-14-reader-paginated-text-layout.md) and
[presentation](../../adr/2026-08-17-reader-text-viewport-presentation.md) ADRs.

Observed facts to revalidate before execution:

- Production is organized under `ios/EpubToMp3/EpubToMp3/App`, `Features` and
  `Shared`; app behavior crosses those directories rather than staying in one file.
- `LibraryStore` has synchronous and asynchronous import entry points; preparation
  uses `LibraryImportExecutor`. A synchronous API is not by itself a UI-blocking
  bug: trace its callers and measure the affected journey before classifying it.
- `ReaderViewportTransition` uses tokens to reject stale commits and cancellation;
  corresponding native tests cover replacement, reentrancy and cancellation.
- `ConversionCallbackBoundary` validates job/version identity and bounds diagnostic
  records; `ConverterFFIAdapter` loads ABI symbols and manages native resources.
- [Package.swift](../../../ios/EpubToMp3/Package.swift) selects a Foundation subset;
  its passing tests cannot establish complete UIKit/AppKit behavior.

## Repeatable process for every bounded finding

1. Record the commit, dirty state, affected target, source/test files, independent
   expected behavior and source of that expectation. Preserve unrelated work.
2. Trace one user action through composition, state owner, asynchronous work,
   persistence and presentation. Map ownership, cancellation and identity at each
   boundary; include alternate entry points such as widgets and incoming URLs.
3. Inspect tests and classify their assertions: real behavior, synthetic dependency,
   source wiring or opt-in journey. Identify uncovered cases before adding tests.
4. Record confirmed defects separately from hypotheses and maintenance proposals.
   Each entry needs trigger, expected/observed result, severity, affected users,
   reproduction scope, evidence location and smallest proposed correction.
5. Reproduce a suspected defect at its native seam using isolated fixtures. Select
   the allowed runtime first. If unavailable, retain a hypothesis or blocked
   acceptance; do not substitute source parsing for a runtime reproduction.
6. Propose one correction and its regression. Obtain confirmation for meaningful
   behavior removal, compatibility or architecture changes, and destructive work.
   Shared conversion defects belong in Rust; record the dependency for phase 4
   rather than creating a second converter in Swift to bypass the ordering.
7. After execution is authorized, demonstrate red-before/green-after where feasible,
   make the narrow change, rerun the original journey and inspect the entire diff.
   Keep native reader production and corresponding native tests in the same commit.
8. Complete that item's required checks, review and PR delivery before the next
   change. An unresolved required runtime gate keeps the item pending; request a
   sequencing decision instead of silently skipping it or calling it complete.

## Ordered review batches

### SW-01 — Startup, incoming documents and import

1. Follow scene activation, incoming URLs and composition in
   [IOSSceneDelegate.swift](../../../ios/EpubToMp3/EpubToMp3/App/IOSSceneDelegate.swift),
   [EpubToMp3App.swift](../../../ios/EpubToMp3/EpubToMp3/App/EpubToMp3App.swift), and
   [MacAppKitRootController.swift](../../../ios/EpubToMp3/EpubToMp3/App/MacAppKitRootController.swift).
   Trace document handling through `Features/Documents/Services` and
   `Features/Library/Services/LibraryImportPreparation.swift`.
2. Check EPUB/PDF type handling, security-scoped access, durable copies, metadata,
   duplicate content, path traversal, missing sources and cancellation during copy.
   Require direct reader navigation and no conversion/playback on book opening.
3. Use [LibraryStoreImportPreparationTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/LibraryStoreImportPreparationTests.swift),
   [EpubDirectoryArchiverSecurityTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/EpubDirectoryArchiverSecurityTests.swift),
   [PdfTextExtractorTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/PdfTextExtractorTests.swift),
   and `EpubToMp3AppDeepLinkTests.swift` as starting seams, not proof of coverage.
4. Compare cold and warm open with identical source identity and cache state;
   distinguish metadata work from first readable content and usable controls.

### SW-02 — Library, persistence and storage

1. Trace [LibraryStore.swift](../../../ios/EpubToMp3/EpubToMp3/Features/Library/Services/LibraryStore.swift),
   library index encoding/persistence, bookmarks, prepared reader caches, and
   [AudioStorageMaintenance.swift](../../../ios/EpubToMp3/EpubToMp3/Features/Offline/Services/AudioStorageMaintenance.swift).
2. Verify successful import/relaunch, failed replacement preserving old bytes,
   corrupted index recovery, missing artifacts, disk-full failures, and cancellation
   while import/removal is in flight. A late completion must not resurrect a removed
   book or bind another book's audio/progress. Verify write order and bounded IO.
3. Separate retained offline listening audio from rebuildable caches. Simulate
   partial cleanup errors in disposable roots; report actual remaining state.
   Never test deletion against the user's library, models or retained audio.
4. Start with [LibraryStoreTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/LibraryStoreTests.swift),
   `AudioStorageMaintenanceTests.swift`, `AudiobookCacheEvictionTests.swift`, and
   [LocalAudioArtifactStoreArtifactFailureIdentityTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/LocalAudioArtifactStoreArtifactFailureIdentityTests.swift).

### SW-03 — Reader, layout, navigation and document fidelity

1. Trace `Features/Reader/Views/BookOpenScreenController.swift`, the Mac reader,
   prepared chapter loading, resource rendering, search, links and TOC identity.
   Compare labels, hierarchy, typography, images, anchors and fallback with the
   input EPUB/PDF; reader format support is distinct from conversion support.
2. Review the existing viewport, transition and paginated-layout owners together.
   Only committed geometry may drive invalidation or clipping checks. Chrome
   changes preserve the exact raw offset; only explicit page turns use canonical
   offsets. Interrupted/replaced transitions must honor the last requested state.
3. Plan seeded Lord of the Rings journeys at small/default font sizes, advanced,
   first/final pages, both page directions, visible/hidden chrome, repeated/rapid
   toggles, scrolling mode, safe-area/orientation changes and oversized fragments.
   Require zero clipped protected fragments and no unexplained location drift.
4. Extend [ReaderViewportTransitionTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/ReaderViewportTransitionTests.swift),
   [ReaderPaginatedTextLayoutTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/ReaderPaginatedTextLayoutTests.swift),
   `ReaderContentSurfaceTests.swift` and the relevant tests in
   [EpubToMp3UITests](../../../ios/EpubToMp3/EpubToMp3UITests), including
   `ReaderModesUIGlyphLayoutTests.swift` and `ReaderModesUIChromePositionTests.swift`.
5. Retain viewport/probe values, visible anchors and screenshots from actual app
   journeys. macOS and required SE1/iOS 15.5 acceptance are distinct; the latter
   remains blocked by Simulator quarantine and cannot be replaced by an iPhone.

### SW-04 — Playback and system controls

1. Follow `Features/Playback/Services/AudioPlayer.swift`,
   [PlaybackSessionLifecycle.swift](../../../ios/EpubToMp3/EpubToMp3/Features/Playback/Services/PlaybackSessionLifecycle.swift),
   queue/segment persistence, pending seeks, resume state and snapshot publication.
   Trace mini/full player, reader, Lock Screen, interruptions and route changes.
2. Verify explicit Play, first audible audio, pause/resume, chapter completion,
   unready seeks, background/foreground, cancellation, and replacement by another
   book. Reject stale decoder/conversion events and retain user pause intent.
3. Exercise missing/corrupt audio, changed chapter identity, system TTS fallback
   and later primary recovery. A playing flag or advancing label alone does not
   prove audible playback; correlate actual decoder/audio and published state.
4. Start with `AudioPlayerInterruptionRecoveryTests.swift`,
   `PlaybackResumeSourceIdentityTests.swift`, `PlaybackSeekExecutionTests.swift`,
   [AudioPlayerDivergencePlayableChapterIdentityTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/AudioPlayerDivergencePlayableChapterIdentityTests.swift),
   and `FullPlayerFittingTests.swift` in the native test directory.
   Use the reader contract for expanded-player layout changes.

### SW-05 — Conversion, FFI and models

1. Trace `RustConversionCoordinator.swift`, manual/listening scheduling, option
   serialization, progress and final manifests in `Features/Conversion/Services`.
   Read [manual conversion](../../../ios/EpubToMp3/docs/manual-conversion.md) and
   [FFI integration](../../../ios/EpubToMp3/docs/converter-ffi-ios.md).
2. Review [ConverterFFIAdapter.swift](../../../ios/EpubToMp3/EpubToMp3/Features/Conversion/Services/ConverterFFIAdapter.swift),
   ABI signatures, native handles/string freeing, callback queues and termination.
   Verify successful completion plus malformed UTF-8/JSON, absent symbols,
   incompatible versions, cancellation, repeated events and foreign/stale job IDs.
3. Verify actual provider/voice reporting, Piper primary retention, bounded recovery
   and explicit job selections. Edge and model installation require explicit user
   action; missing models must not silently trigger downloads or online fallback.
4. Start with [ConversionCallbackBoundaryTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/ConversionCallbackBoundaryTests.swift),
   [ConverterFFIStringOwnershipTests.swift](../../../ios/EpubToMp3/EpubToMp3Tests/ConverterFFIStringOwnershipTests.swift),
   `ManualConversionSessionTests.swift`, `ConversionOptionsInteropWireIdentityTests.swift`
   and `SpeechModelBackgroundTransferTests.swift`. Keep fake-ABI and real-FFI
   evidence separate; a Swift callback test does not validate Rust ownership alone.

### SW-06 — Settings, extensions, accessibility, privacy and native tools

1. Review `Features/Settings`, `Shared/Configuration`, localization resources,
   [WidgetDataSync.swift](../../../ios/EpubToMp3/EpubToMp3/Shared/Integrations/WidgetDataSync.swift),
   `Shared/Integrations/ConversionActivityAttributes.swift`, widget intents, and
   [ShareViewController.swift](../../../ios/EpubToMp3/EpubToMp3ShareExtension/ShareViewController.swift).
2. Verify settings persistence, App Group/serialized identity, extension target
   membership, missing permissions, stale widget updates and cancelled transfers.
   Check VoiceOver labels/order/actions, Dynamic Type, contrast, semantic materials,
   keyboard navigation, supported locales and format placeholders in real surfaces.
3. Inspect diagnostics and retained evidence for book text, paths and document
   picker contents. Use synthetic fixtures and redact private captures before any
   publication. Test that rejected callback payloads do not enter logs.
4. Start with `WidgetDataSyncTests.swift`, `SharedContainerImporterTests.swift`,
   `MacSettingsStorageFailureTests.swift`, `NativeFormAccessibilityTests.swift`,
   `LocalizationParityTests.swift` and `LatencyObservationPersistenceTests.swift`.
5. Review [DeviceWorkflow](../../../tools/DeviceWorkflow) scope, process identity,
   cancellation, cleanup and reports against its Swift tests. Inspect bootstrap
   behavior before executing any host task: tool compilation requires its own gate.

## Validation routes and execution limits

Read the exact [mise tasks](../../../mise.toml) and nested scripts before use.
These are planned routes, not commands executed by this document:

| Route | What it can establish | Boundary |
| --- | --- | --- |
| `apple:foundation:test` | Selected actual Foundation production seams | Compiles Swift; excludes full UI/AVFoundation acceptance |
| `apple:foundation:ffi:test` | Selected Swift calls into real host FFI | Explicitly builds Rust; ask about verified prebuilts first |
| `mac:validate` modes | Separate identity, packaging, app build and visible GUI | Use the smallest explicit mode and existing compatible artifacts |
| `ios:device:test` | Focused authorized physical-iPhone tests | Requires explicit `IOS_TESTS` allowlist selection and device scope |
| `native:xcresult` | Serialized reading/export of completed result bundles | Evidence extraction, not test execution |
| `hooks:reader-check` | Native production/test change pairing | Does not establish reader behavior |

The device runner's [Scope.swift](../../../tools/DeviceWorkflow/Sources/DeviceWorkflow/Scope.swift)
validates selected methods/classes. Test source presence is not executable-route
coverage: the newly preserved `PhysicalPDFJourneyTests.swift` is not listed in that
allowlist at planning time. Review guards and any routing change before a journey.
Do not use generic `ios:test` as a shortcut: it contains a Simulator fallback.

Before heavy compilation, inspect storage and use the native lease with one job.
Ask about matched prebuilts before dependency/runtime/tool compilation, including
bootstrap paths. Use Xcode 26.3 per command for the physical iPhone 16e, preserve
global selection, and retain required legacy compatibility. Never boot Simulator
or download runtimes through this plan. A new kernel panic is a stop event under
the execution policy; no automatic retry or bypass is permitted.

## Exit record and handoff

For each batch, record reviewed files/exclusions and findings with severity,
confidence, ownership and dependencies. For each correction record exact source,
configuration, fixture identity, commands, pass/fail/skip counts, observed app
behavior, evidence paths, PR/commit and required CI state. Keep private execution
notes local; publish only reviewed product documentation and scoped changes.

Leave blocked reader/device acceptance visible. Do not declare phase completion
from build success, existing test names, screenshots alone or a coverage percentage.
After the phase's accepted items are integrated, hand the remaining hypotheses,
shared-Rust dependencies and measured build concerns to phases 3 and 4.
