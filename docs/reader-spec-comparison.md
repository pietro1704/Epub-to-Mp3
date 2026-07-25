# Reader Specification — Comparison with Current App

This comparison was performed after the product specification and wireframes
were completed. It describes the current repository without changing its
implementation.

## Executive summary

The current app is a strong partial implementation of the proposed product,
not a blank starting point. Its architecture already matches the most
important strategic decisions: native UIKit on iOS, native AppKit on macOS,
embedded Python as the canonical parser/conversion path, local library and
cache, chapter streaming, offline downloads, and a persistent audiobook player.

The largest gap is the reading surface. The current reader can display EPUB
HTML/text and PDF documents, but its main iOS/macOS flow is still chapter-list
plus text-view based rather than a complete Apple Books-style reading engine
with robust pagination, semantic anchors, annotations, and unified visual and
speech representations.

## Capability matrix

| Requirement | Current state | Result |
|---|---|---|
| iOS native UIKit | `IOSRootContainerController`, UIKit screens, no SwiftUI screen dependency | Aligned |
| macOS native AppKit | `MacAppKitRootController`, `MacLibraryViewController`, AppKit reader/player | Aligned |
| No SwiftUI app screens | Source-contract tests reject SwiftUI imports and hosting bridges in the main app | Aligned in code; some docs are stale |
| Apple Books-style library | Local library, covers, metadata, search/grid, import, tags and progress models | Mostly aligned |
| EPUB | Python parser embedded in the Apple target, EPUB metadata and HTML renderer | Aligned |
| PDF | PDFKit reader and text extraction with outline/heuristic chapter grouping | Aligned, with scanned-PDF limitation |
| MOBI/AZW/AZW3/FB2/CBZ/CBR/DOCX | `BookFileType` and pickers currently expose only EPUB/PDF | Missing |
| Local-first reading | App-owned imported files, bookmarks, full-text cache and persistent local state | Aligned |
| Explicit offline downloads | `DownloadManager`, `ChapterCacheManager`, full-text cache and eviction | Mostly aligned |
| On-device conversion | Embedded Python, Piper/Edge bridges and chapter conversion | Aligned |
| Server conversion option | API client, jobs and Edge transport exist; provider choice is configurable infrastructure | Partially aligned; needs explicit product UX and provider contract |
| Chapter streaming | `AudioPlayer` and streaming conversion state enqueue playable material as it arrives | Aligned |
| Persistent mini-player | iOS overlay and macOS player bar survive library/reader navigation | Aligned |
| Full player | Native UIKit/AppKit full-player controllers, queue, rate, chapter navigation, sleep timer | Aligned |
| Background audio | Audio background mode, `AVAudioSession`, interruption and route handling | Aligned on iOS |
| Lock Screen / Control Center | `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, widget and tests | Aligned |
| Headphones and external routes | Remote commands, audio session and AirPlay route picker | Aligned |
| CarPlay | No CarPlay scene/template/controller was found | Missing |
| Pagination and continuous scroll | Scrolling text reader and keyboard page stepping exist; true book pagination is not complete | Partial |
| Preserved typography and spacing | Python exposes formatting/HTML/CSS; native `EpubHtmlRenderer` exists, but the main reader currently sets plain `chapter.text` | Partial / integration gap |
| Footnotes in speech | Python reader has footnote extraction and speech cue processing | Aligned in backend; native semantic rendering needs completion |
| Search | Library search exists; reader-level full-text search was not established in the main reader flow | Partial |
| Bookmarks | `BookmarkStore` and bookmark tests exist | Partial; text-range/anchor UI needs completion |
| Notes/highlights | Highlight-related tests and models exist, but the end-to-end annotation UX is not complete in the main reader | Partial |
| TOC hierarchy | EPUB/PDF chapter structures and TOC controllers exist | Mostly aligned; current display is chapter-oriented |
| Sync later | Sync/CloudKit services and tests already exist | Infrastructure exists; intentionally outside v1 product scope |
| Accessibility | Dynamic Type-compatible controls, VoiceOver identifiers and contrast tests exist | Mostly aligned; needs reader acceptance pass |
| Performance | Python call serialization, lazy caches, chapter caches, eviction and watchdogs exist | Strong foundation; reader rendering still needs profiling |

## Evidence by area

### Native platform shell

- [IOSRootContainer.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/App/IOSRootContainer.swift)
  owns the UIKit iOS shell, reader, mini-player, and full player overlays.
- [MacAppKitRootController.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/App/MacAppKitRootController.swift)
  owns the native macOS split-view shell and player bar.
- [IOSAppShellTests.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3Tests/IOSAppShellTests.swift)
  explicitly protects the no-SwiftUI main-app contract.

### Library and offline storage

- [LibraryStore.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Library/Services/LibraryStore.swift)
  hashes imported content, copies it into app-owned storage, persists access,
  extracts metadata, and de-duplicates books.
- [BookEntity.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Library/Models/BookEntity.swift)
  already models file type, progress, cover, conversion and offline state.
- [DownloadManager.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Offline/Services/DownloadManager.swift)
  provides background-capable download and storage handling.

### Reader and Python reference

- [PythonBridge.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Conversion/Services/PythonBridge.swift)
  routes Apple parsing/conversion through the embedded Python pipeline.
- [ebook_reader.py](/Users/pietropugliesi/Developer/Epub-to-Mp3/python_app/src/ebook_reader.py)
  already handles EPUB/PDF, TOC structure, formatting segments, footnotes,
  speech cues, duplicate detection, and persistent parsing cache.
- [BookOpenScreenController.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift)
  currently renders the iOS text path through a `UITextView` and exposes EPUB
  and PDF import types only.
- [MacReaderViewController.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Reader/Views/MacReaderViewController.swift)
  currently renders the macOS text path through an `NSTextView` and supports
  keyboard page-like scrolling.
- [EpubHtmlRenderer.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Reader/Services/EpubHtmlRenderer.swift)
  is capable of preserving HTML/CSS formatting, but the main reader flow must
  use it consistently instead of assigning only plain chapter text.

### Audio player

- [AudioPlayer.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Playback/Services/AudioPlayer.swift)
  already integrates audio sessions, remote commands, Now Playing metadata,
  interruptions, chapter progression, conversion streaming, and resume state.
- [MiniPlayerBarHost.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Playback/Views/MiniPlayerBarHost.swift)
  provides the persistent iOS mini-player.
- [FullPlayerScreenController.swift](/Users/pietropugliesi/Developer/Epub-to-Mp3/ios/EpubToMp3/EpubToMp3/Features/Playback/Views/FullPlayerScreenController.swift)
  provides the native full-player surface.

## Priority gaps

### P0 — reader fidelity and product flow

1. Replace the current plain-text chapter presentation with a semantic reader
   model that can render HTML/CSS, formatting runs, footnotes, images, links,
   headings, spacing, and stable source anchors on iOS and macOS.
2. Implement a single reader state machine for pagination, continuous scroll,
   chapter transitions, progress restoration, and audio-following.
3. Integrate bookmark, selection, highlight, note, and search actions with
   stable semantic anchors instead of chapter-only indexes.
4. Make the Book Detail → Read/Listen/Download flow the primary product path;
   keep the existing conversion/jobs surface as an advanced/diagnostic view.

### P1 — format and conversion expansion

1. Extend format detection, import UTTypes, metadata, parsing, rendering,
   speech normalization, and test fixtures for MOBI, AZW/AZW3, FB2, CBZ/CBR,
   and DOCX.
2. Define a provider protocol whose default is on-device and whose explicit
   alternative is server conversion, including progress, retries, errors,
   cancellation, and offline eligibility.
3. Add a conversion settings sheet matching the wireframe and preserve current
   voice/language/rate defaults.

### P1 — media system completeness

1. Add a CarPlay scene and audiobook browse/now-playing templates.
2. Verify real-device behavior for Lock Screen, Control Center, headphones,
   AirPlay, background suspension, interruptions, and chapter handoff.
3. Keep the player as one injected application service shared by every screen.

### P2 — documentation and future sync

1. Update older architecture documents that still describe SwiftUI as an app
   surface; the current direction is UIKit/AppKit except permitted widgets and
   Live Activities.
2. Keep CloudKit/sync code behind a future account boundary; do not let it
   complicate the local-only v1 storage contract.

## Recommended implementation decision

Do not replace the current native shell or audio player. Treat them as the
foundation and concentrate the next design/implementation slice on a semantic
reader core plus a Book Detail flow. The Python reader should remain the shared
content and speech reference, but its output contract needs to be promoted from
chapter text with optional fields to a stable semantic document model used by
visual rendering, annotations, progress, search, and TTS.
