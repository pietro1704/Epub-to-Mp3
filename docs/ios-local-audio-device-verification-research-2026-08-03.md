# iPhone Local Audio Evidence and Regression Research

Status: resolved research for [Audit iPhone evidence and regression seams for local audio](https://github.com/pietro1704/Epub-to-Mp3/issues/468).

## Primary sources

- `ios/EpubToMp3/EpubToMp3Tests/AudioPlayerStreamingTests.swift`
- `ios/EpubToMp3/EpubToMp3Tests/AudioPlayerEnqueueSegmentTests.swift`
- `ios/EpubToMp3/EpubToMp3Tests/EmbeddedConversionCoordinatorTests.swift`
- `ios/EpubToMp3/EpubToMp3Tests/PythonEmbedTests.swift`
- `ios/EpubToMp3/EpubToMp3Tests/SegmentBacklogTests.swift`
- `ios/EpubToMp3/EpubToMp3UITests/ReaderLoadingRegressionUITests.swift`
- `mise.toml:528-645,825-913`

## Existing evidence

- Unit tests exercise streaming queue behavior, segment ordering, first-segment readiness, no-autoplay until user intent, backlog teardown, cache policy helpers, embedded snapshot repair, and Python streaming output.
- A network-backed PythonEmbed test proves the native Edge bridge can receive MP3 data when the test environment allows it.
- Reader UI tests cover loading, pagination, immersive chrome, mini-player access, and compact full-player layout.
- `mise run ios:device:build`, `mise run ios:device:run`, and `mise run ios:device:test` target a paired physical iPhone and intentionally avoid relying on CoreSimulator.

## Missing evidence

- No test proves a local generated chapter can be promoted to a protected offline download without a remote URL.
- No test covers the requested chapter priority, book FIFO queue, Wi-Fi waiting state, two-attempt terminal error, or a retry that preserves completed chapters.
- No test checks that explicit downloads survive eviction while temporary generated audio is evicted.
- No test or production implementation proves ZIP generation, partial-export manifest contents, or the iOS share sheet.
- Existing UI tests do not prove a real device completes the Edge-to-AVFoundation round trip, Lock Screen continuity, relaunch offline playback, or real network interruption behavior.

## Recommended acceptance harness

1. XCTest seams: local artifact manifest state transitions, priority scheduling, retry counting, local-file promotion, protected-vs-temporary eviction, and ZIP manifest generation.
2. UI-test seams: TOC row state/action, top-level whole-book state, waiting-for-Wi-Fi state, retry-all visibility, and Settings storage actions. These tests should not require a live Edge service.
3. Real iPhone gate: import the seeded Lord of the Rings EPUB; tap Listen at a non-first chapter; observe first playable audio; lock/unlock during playback; request one TOC download and then whole-book download; disable Wi-Fi to observe waiting; relaunch and play a protected local chapter; export a partial ZIP; capture device logs and LLDB output.
4. Device result is the only proof of actual audio output, background behavior, and network lifecycle. A successful build or unit test is not a substitute.
