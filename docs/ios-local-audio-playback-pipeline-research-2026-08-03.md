# iPhone Local Audio Playback Pipeline Research

Status: resolved research for [Trace the iOS embedded conversion-to-playback pipeline](https://github.com/pietro1704/Epub-to-Mp3/issues/466).

## Primary sources

- `ios/EpubToMp3/EpubToMp3/Features/Library/Views/BookDetailScreenController.swift:152-181`
- `ios/EpubToMp3/EpubToMp3/Features/Conversion/Services/EmbeddedConversionCoordinator.swift:44-389`
- `ios/EpubToMp3/EpubToMp3/Features/Conversion/Services/PythonBridge.swift:589-720`
- `ios/EpubToMp3/EpubToMp3/Features/Playback/Services/AudioPlayer.swift:1110-1138,1791-2041`
- `ios/EpubToMp3/EpubToMp3Tests/AudioPlayerStreamingTests.swift`

## Current path

1. The book detail starts `EmbeddedConversionCoordinator.stream` for an embedded job.
2. `EmbeddedConversionCoordinator` parses/caches full text, creates a pending `JobSnapshot`, resets the shared `AudioPlayer`, and starts the player with that snapshot.
3. `PythonBridge.convertChapterStreaming` delivers each Edge MP3 chunk to `AudioPlayer.enqueueSegment` while it also writes the complete chapter file.
4. `AudioPlayer` writes every live segment into one temporary session directory and feeds an `AVQueuePlayer`. At conversion completion it swaps the temporary segment queue for the full chapter files through `finishEmbeddedStreaming`.
5. The coordinator persists a live `JobSnapshot` after every completed or failed chapter. A fully completed snapshot can be reused after relaunch when every `file://` chapter URL is valid.

## Verified strengths

- Segment bytes are file-backed before being inserted into `AVQueuePlayer`, so playback can start before the full chapter is written.
- Late callbacks are fenced by a stream lease.
- Segment identity deduplication and the bounded backlog protect ordering and memory pressure.
- The final chapter-file handoff restores seeking and normal offline playback.
- XCTest already covers first-segment readiness, explicit playback intent, ordering, teardown, and the snapshot handoff.

## Gaps against the confirmed contract

- `stream` has a single static `activeStream`. A request for another book calls `cancel(active)`, which stops the player and clears conversion state instead of pausing the prior book in a FIFO queue.
- The conversion loop iterates `narratable` in EPUB order. It has no request model for the reader's current chapter, manually requested TOC chapters, or a priority queue.
- Coordinator-level failure handling records a failed chapter and advances. The retry policy lives lower in `PythonBridge` and is currently unrelated to the confirmed two-attempt, user-visible chapter policy.
- There is no persisted conversion-queue model, so app foreground/relaunch cannot restore active and paused book work deterministically.
- The shared player owns playback state correctly, but it must not become the conversion scheduler. Scheduling belongs above `EmbeddedConversionCoordinator`; player input remains ordered segments and a canonical final snapshot.

## Smallest safe ownership boundary

Introduce one iOS-local conversion scheduler above `EmbeddedConversionCoordinator`. It owns book-level FIFO state, chapter priorities, Wi-Fi waiting, retry budget, and persistence. It invokes the coordinator for one unit of book work and continues to send the same segment/final-snapshot interface to `AudioPlayer`. This avoids changing AVFoundation queue ownership while removing the global `activeStream` cancellation behavior.
