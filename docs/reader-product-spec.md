# Epub-to-MP3 Reader — Product and Engineering Specification

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
offline use. Text-to-speech conversion must work on-device by default, with a
server option selected from Settings. Conversion must stream chapter audio as
it becomes available, preserve chapter structure, and read the complete book,
including footnotes, typography changes, paragraphs, spacing, and meaningful
layout cues. The existing Python reader is the parsing reference and may be
improved when required for faithful reading.

The design must use UIKit/AppKit, never SwiftUI, follow Apple Human Interface
Guidelines and Apple platform conventions, apply SOLID principles, maximize
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
- Backend as a contract: clients must not share implementation types across
  platforms; future clients consume the same documented API.

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
- On-device TTS by default; server conversion as an explicit Settings option.
- Chapter-level conversion, streaming playback, pause/resume, retry, cache,
  and explicit offline download.
- Persistent audio player and all Apple media integration points.
- Voice, language, rate, chapter, and conversion settings with working
  defaults preserved.

### Later releases

- Account and cloud synchronization of library, progress, bookmarks, notes,
  settings, generated audio, and downloads.
- Android, Windows, Linux, and web clients derived from the same backend
  contract and product behavior.

## 4. Core user journeys

### Import and read

1. User imports a supported book.
2. App validates format, extracts metadata/cover, and adds it to Library.
3. User selects the book and sees its detail page.
4. User taps Read; the app restores the last position or opens the beginning.
5. Reader presents paginated or continuous text and exposes TOC, search,
   bookmarks, notes, typography, and theme controls.

### Convert and listen

1. User opens the book detail page or reader player action.
2. App presents conversion scope: current chapter, selected chapters, or all.
3. Device conversion is selected by default; server conversion is available
   from Settings.
4. Conversion begins chapter by chapter.
5. Completed chapters become playable immediately and can be downloaded.
6. The persistent player continues across Library, book detail, reader, and
   Settings without interrupting playback.

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

Use a feature-oriented UIKit/AppKit application with protocol-driven services:

- `LibraryFeature`: library screens, import, metadata, and local indexing.
- `ReaderFeature`: layout, pagination, scrolling, selection, annotations,
  TOC, and search.
- `AudioFeature`: conversion orchestration, chapter streaming, downloads,
  queue, Now Playing, remote commands, and background audio.
- `SettingsFeature`: reader, audio, storage, and provider configuration.
- `CoreDomain`: format-neutral models and use cases.
- `CoreStorage`: SQLite/Core Data-backed metadata plus file/blob storage.
- `CoreParsing`: adapter around the Python reader contract and native format
  adapters where appropriate.
- `CoreNetworking`: versioned API client for optional server conversion and
  future sync.

Apply dependency inversion: view controllers depend on use-case protocols;
use cases depend on repository protocols; concrete storage, parsing, audio,
and network implementations are injected at composition roots.

## 7. Python reader contract

The Python reader remains the parsing oracle for the first implementation.
Its output must expose a stable semantic representation rather than only
plain text. Required fidelity includes:

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
- Native source-contract tests proving UIKit/AppKit usage and no SwiftUI target
  dependency.
- Performance tests for first render, memory, chapter scrolling, and audio
  start latency.

Acceptance means a user can import a non-DRM book, read it offline, resume at
the correct location, annotate it, start on-device conversion, hear completed
chapters while conversion continues, leave the reader without interrupting
audio, and control playback from every supported Apple media surface.

## 10. Implementation phases

1. Domain contracts, storage schema, format fixture suite, and Python reader
   semantic output.
2. Local import pipeline, library, metadata, cover handling, and indexing.
3. Reader engine: pagination, scrolling, TOC, search, progress, themes,
   typography, selection, bookmarks, and notes.
4. On-device conversion, chapter streaming, cache, downloads, and retries.
5. Persistent player, background audio, Now Playing, remote commands,
   Lock Screen, Control Center, CarPlay, and headphones.
6. Optional server provider, API contract, diagnostics, and migration path.
7. Performance hardening, accessibility, localization, release validation,
   and design review against HIG.

## 11. Reference documentation

- [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [UIKit](https://developer.apple.com/documentation/uikit)
- [AVFoundation](https://developer.apple.com/av-foundation/)
- [MediaPlayer](https://developer.apple.com/documentation/mediaplayer)
- [Background execution](https://developer.apple.com/documentation/backgroundtasks)
- [CarPlay](https://developer.apple.com/carplay/)
