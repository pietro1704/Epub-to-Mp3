# Epub-to-MP3 Reader — Product and Engineering Specification

This document records product targets and design requirements, not an implemented
capability inventory or a runtime acceptance report. Check the current adapter
and affected real app before claiming a format, feature or platform is supported.
[CONTEXT.md](../CONTEXT.md), relevant ADRs and the
[native reader contract](../ios/EpubToMp3/AGENTS.md) govern current terminology and
geometry; [execution policy](agents/execution-policy.md) governs validation.

## 1. Ideal product prompt

Design a high-performance native book reader for iOS and macOS, later
derivable to Android, Windows, Linux, and web. It must support EPUB, PDF,
MOBI, AZW/AZW3, FB2, CBZ/CBR, and DOCX when the file is not protected by DRM.
The reading experience should follow Apple Books, while audio playback should
behave like Spotify: a persistent player, background playback, system media
controls, and playback that survives navigation across the app.

The first release is local-first and offline-capable. Users can import books
from every supported Apple file-sharing surface, add them to a local library,
open them in a reader, and explicitly download books or generated audio for
offline use. Text-to-speech conversion runs locally through the embedded shared Rust
runtime; Settings selects supported installed or explicitly consented providers. Conversion must stream chapter audio as
it becomes available, preserve chapter structure, and read the complete book,
including footnotes, typography changes, paragraphs, spacing, and meaningful
layout cues. Shared parsing and conversion behavior belongs in Rust. Retained Python parsing
fixtures may serve as migration references; they are not an Apple runtime
dependency or an unquestioned fidelity oracle.

The main Apple application surfaces use UIKit/AppKit; WidgetKit and related
extensions may use their required SwiftUI APIs. Follow Apple Human Interface
Guidelines and Apple platform conventions, favor narrow concrete modules, maximize
performance, and include product requirements, UX flows, domain architecture,
storage, APIs, testing strategy, implementation phases, acceptance criteria,
navigation mapping, and textual wireframes.

## 2. Product principles

- Local-first: opening, reading, progress, bookmarks, notes, and downloaded
  media remain useful without a network connection.
- Apple Books familiarity: library, book detail, table of contents, reader
  controls, pagination, and document hierarchy should feel native.
- Spotify-grade audio continuity: one global playback session, persistent
  mini-player, Now Playing screen, queue of chapters, lock-screen controls,
  Control Center, CarPlay, headphones, and background audio.
- Complete semantic reading: parsing must preserve content and meaningful
  structure instead of flattening a book into an opaque text blob.
- Performance first: lazy loading, bounded memory, incremental parsing,
  chapter-level caching, streaming audio, and hardware-appropriate concurrency.
- Shared core as a contract: Rust owns parsing, conversion, provider policy,
  progress, cancellation and artifacts; clients use native FFI, CLI or WASM
  adapters. The standalone HTTP compatibility service remains outside the
  native/browser local conversion contract.

## 3. Release scope

### Version 1 — iOS and macOS, local-only

- Import all supported non-DRM formats through Files, iCloud Drive, AirDrop,
  Finder, Share Sheet, document URLs, and security-scoped bookmarks.
- Local library with cover, metadata, sorting, filtering, search, and cleanup.
- Apple Books-style reader with pagination and continuous scrolling.
- Table of contents with hierarchy and chapter navigation.
- Reading progress, resume position, bookmarks, notes, and text search.
- Light, dark, and system themes; font family, size, spacing, margins, and
  reading direction controls where the format supports them.
- Local shared-Rust conversion with explicit provider preferences and model installation.
- Chapter-level conversion, streaming playback, pause/resume, retry, cache,
  and explicit offline download.
- Persistent audio player and all Apple media integration points.
- Voice, language, rate, chapter, and conversion settings with working
  defaults preserved.

### Later releases

- Account and cloud synchronization of library, progress, bookmarks, notes,
  settings, generated audio, and downloads.
- Android, Windows, Linux, and web clients using the same shared Rust
  conversion contract and product behavior.

## 4. Core user journeys

### Import and read

1. User imports a supported book.
2. App validates format, extracts metadata/cover, and adds it to Library.
3. User selects the book and sees its detail page.
4. User taps Read; the app restores the last position or opens the beginning.
5. Reader presents paginated or continuous text and exposes TOC, search,
   bookmarks, notes, typography, and theme controls.

### Listen from the reader

1. Opening a book restores readable content and position without starting
   conversion or playback.
2. An explicit Play request asks the active book screen to populate the audio
   queue through the local Rust conversion path when required.
3. Playback starts after the first validated playable audio is queued; later
   chapters join progressively, preserving the captured provider preferences.
4. The persistent player continues across Library, book detail, reader and
   Settings. Reader navigation and the current playback position remain distinct
   until the listener explicitly chooses to move playback.

### Manual conversion and full-book download

1. The dedicated Convert destination owns explicit manual conversion and its
   supported chapter scope. The reader has no separate Converter action.
2. Library Download all opens Convert with a full-book request and no chapter
   range.
3. Rust converts progressively and persists artifacts. Manual conversion leaves
   playback under the listener's explicit control; it does not autoplay.
4. The listener can play queued output or retain available chapter audio for
   offline listening through the existing player and download controls.

### Offline use

1. User chooses Download for a book, chapters, or generated audio.
2. App records download state and available local assets.
3. Reader and player prefer local assets when offline.
4. Failed or partial downloads can resume without rebuilding valid cache.

## 5. Domain model

- `Book`: stable local identifier, source URL/bookmark, format, metadata,
  cover, import date, last opened date, and storage state.
- `BookContent`: chapters, semantic blocks, anchors, footnotes, typography
  runs, page information, and source-to-content mappings.
- `Chapter`: hierarchy, title, order, text blocks, footnotes, estimated
  duration, parsing status, and audio status.
- `ReadingProgress`: book/chapter/anchor, fraction, timestamp, and device ID.
- `Bookmark`: stable content anchor, label, excerpt, color, and timestamp.
- `Note`: stable content range, text, highlight style, and timestamp.
- `AudioAsset`: chapter, engine, voice, language, duration, local path,
  download state, checksum, and generation status.
- `PlaybackSession`: current book/chapter, position, queue, rate, and state.
- `ReaderSettings`: theme, font, size, margins, spacing, pagination mode,
  narration cues, voice, language, rate, and conversion provider.

## 6. Native architecture

Use feature-oriented UIKit/AppKit modules with narrow interfaces at real seams:

- `LibraryFeature`: library screens, import, metadata, and local indexing.
- `ReaderFeature`: layout, pagination, scrolling, selection, annotations,
  TOC, and search.
- `AudioFeature`: conversion intent/progress presentation and playback adapters
  for chapter streaming, downloads, queue, Now Playing, remote commands and
  background audio. Rust owns conversion-job orchestration, retry and cancellation.
- `SettingsFeature`: reader, audio, storage, and provider configuration.
- `CoreDomain`: format-neutral models and use cases.
- `CoreStorage`: existing persisted metadata and file/artifact storage, changed
  only when a concrete persistence requirement justifies a new adapter.
- `CoreParsing`: shared Rust parser contracts and format adapters, preserving
  semantic fidelity through native FFI and browser/WASM boundaries.
- `CoreNetworking`: platform networking for explicitly selected online providers
  and separately scoped future synchronization. Conversion remains owned by
  the embedded Rust runtime.

Keep viewport transition and pagination responsibilities in their owning deep
modules. Use concrete services by default; introduce a protocol when actual
adapters or an external platform seam require it. Inject platform implementations
at composition roots without adding an interface for every layer.

## 7. Semantic reader contract

The shared parser output must expose a stable semantic representation rather
than only plain text. Legacy fixtures can inform differential checks; assess
disagreements against the original document. Required fidelity includes:

- EPUB NCX and EPUB3 navigation hierarchy;
- chapter titles and anchors;
- paragraphs and spacing;
- headings and section boundaries;
- emphasis, bold, italics, links, quotations, and code-like blocks;
- footnote references and footnote bodies;
- meaningful lists and tables;
- image descriptions when available;
- page boundaries for fixed-layout/PDF sources;
- reading-order metadata for speech.

The speech representation may add cues for typography and structure, but must
not alter the visual representation or lose source locations needed by search,
annotations, and progress restoration.

## 8. Performance requirements

- Parse metadata and first readable chapter before opening the reader.
- Parse remaining chapters lazily and cache validated results.
- Render only the visible window plus a small prefetch window.
- Keep audio generation chapter-scoped and stream completed assets immediately.
- Resume interrupted conversion/download from checksummed chunks or chapters.
- Avoid duplicate parsing, duplicate TTS requests, and duplicate audio files.
- Instrument import latency, first-render latency, chapter render time, TTS
  throughput, memory peaks, dropped frames, and audio interruptions.

## 9. Testing and acceptance criteria

- Unit tests for each use case, parser adapter, repository, and state machine.
- Format fixtures for EPUB2/EPUB3, PDF, MOBI/AZW, FB2, CBZ/CBR, and DOCX.
- Regression fixtures for footnotes, typography changes, nested TOCs, shared
  anchors, empty chapters, oversized chapters, tables, and duplicate content.
- Integration tests for import → library → reader → annotation → conversion →
  streaming playback → offline playback.
- Native runtime tests at the affected reader seam, covering glyph containment,
  final viewport geometry, exact offset restoration and canonical page turns.
  Source scans alone cannot prove rendering or interaction correctness.
- Performance tests for first render, memory, chapter scrolling, and audio
  start latency.

These are target acceptance criteria, not a claim that the listed journeys or
formats passed. Required SE1/iOS 15.5 validation remains blocked while Simulator
execution is quarantined; another runtime cannot substitute for it.

Acceptance means a user can import a non-DRM book, read it offline, resume at
the correct location, annotate it, start on-device conversion, hear completed
chapters while conversion continues, leave the reader without interrupting
audio, and control playback from every supported Apple media surface.

## 10. Implementation phases

1. Domain contracts, storage schema, format fixture suite, and shared Rust
   semantic output.
2. Local import pipeline, library, metadata, cover handling, and indexing.
3. Reader engine: pagination, scrolling, TOC, search, progress, themes,
   typography, selection, bookmarks, and notes.
4. On-device conversion, chapter streaming, cache, downloads, and retries.
5. Persistent player, background audio, Now Playing, remote commands,
   Lock Screen, Control Center, CarPlay, and headphones.
6. Diagnostics and separately scoped future synchronization contracts.
7. Performance hardening, accessibility, localization, release validation,
   and design review against HIG.

## 11. Reference documentation

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [UIKit](https://developer.apple.com/documentation/uikit)
- [AVFoundation](https://developer.apple.com/av-foundation/)
- [MediaPlayer](https://developer.apple.com/documentation/mediaplayer)
- [Background execution](https://developer.apple.com/documentation/backgroundtasks)
- [CarPlay](https://developer.apple.com/carplay/)
