# iPhone Local Audio Implementation Specification

## Objective

Make the iPhone audio experience reliable without an application backend: Edge
may generate speech over Wi-Fi, but the app owns scheduling, streamed
playback, durable downloads, retention, and ZIP export.

## Product contract

- Conversion and downloads use Wi-Fi by default; cellular use is an explicit
  Settings preference.
- One book converts at a time. Other books remain in FIFO paused state.
- The reader and expanded player use one TOC. Its rows expose per-chapter
  state, download/remove, retry, and priority actions. The top action handles
  the whole book.
- Listening prioritizes the current reader chapter and starts once its first
  valid segment is available. Explicit TOC requests follow the active segment
  in tap order, then normal book order resumes.
- Completed buffered/downloaded audio plays in background and on the Lock
  Screen. Wi-Fi loss is a waiting state, never a skipped chapter or silent
  system-speech fallback.
- A chapter receives two Edge attempts in total. Failed chapters retain
  completed work and expose row-level plus conditional bulk retry.
- Explicit downloads never expire automatically. Temporary generated audio is
  evictable under an adaptive cap of the smaller of 2 GB and 10% of free
  storage. Low space pauses safely.
- Export produces a shareable ZIP of available MP3s and a manifest listing
  missing/failed chapters. It never starts hidden conversion.

## Architecture

### LocalAudioArtifactStore

This new application service is the only local-audio persistence authority.
It owns a versioned book manifest and stable MP3 locations in app-owned
Application Support. Each chapter records title, local URL, availability,
retention, retry state, and last error. `JobSnapshot` remains a UI/player
projection, not persistent truth.

An explicit download promotes the same valid generated artifact to protected
retention. It does not duplicate or re-download a `file://` MP3. Legacy
`DownloadManager` APIs delegate to this store until remote-backend opt-in is
revisited. The independent `ChapterCacheManager` synthesis path is removed
from iOS user flows.

### LocalConversionScheduler

This service owns one active book, paused FIFO books, priority chapter work,
two-attempt failures, Wi-Fi waiting, and persisted resume state. It invokes
`EmbeddedConversionCoordinator` for actual parsing/Edge segment generation.
`AudioPlayer` continues to own AVFoundation, temporary segment buffering, and
the final full-file queue handoff; it does not schedule conversion work.

### UI and export

TOC rows render the artifact-store state. The whole-book action queues missing
chapters and marks them protected. Settings exposes Wi-Fi policy, storage
usage split by temporary/protected audio, safe temporary-cache cleanup, and
per-book management. ZIP export reads only durable or currently available
artifacts through the manifest and presents a native share sheet.

## Pre-agreed XCTest seams

- `LocalAudioArtifactStore`: promotion, state transitions, manifest recovery,
  protected-versus-temporary eviction candidates, and local URL resolution.
- `LocalConversionScheduler`: FIFO behavior, chapter-priority ordering, Wi-Fi
  waiting/resume, retry budget, and completed-work preservation.
- ZIP builder: ordered MP3 membership and partial-export manifest contents.
- Existing `AudioPlayer`: receives ordered segments and a final snapshot only.

## Pre-agreed UI-test seams

- Reader/full-player shared TOC row and whole-book actions.
- Waiting, failed, retry-all, protected-download, and partial-export states.
- Settings Wi-Fi/storage actions using deterministic local fixtures.

## Minimal simulator gate

Use Xcode 16.4 with the iOS 15.0 runtime and an iPhone SE (1st generation).
Use the seeded Lord of the Rings EPUB to prove a non-first current chapter
streams audio before completion; chapter and whole-book download state
updates; Wi-Fi waiting resumes; relaunch plays protected audio offline; and
partial ZIP export opens the share sheet. Record measured time to first
playable segment and attach LLDB/simulator-log evidence. Lock Screen and
background-audio behavior remain device-only follow-up checks.

## Non-goals

- Remote backend opt-in.
- Fully offline neural TTS and model distribution.
- macOS, Flutter, Android, web, or CLI feature parity in this delivery.
