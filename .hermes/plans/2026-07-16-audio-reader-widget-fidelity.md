# Audio, Reader, Widget and Book Fidelity Correction Plan

> For Hermes: execute task-by-task with TDD, one focused commit per task, and physical-iPhone verification before declaring success.

Goal: make audiobook playback reliable in background/lock screen, synchronize widget and Reader ↔ Player bidirectionally, expose chapter-level progress, make “Tocar daqui” reliable, and render EPUB/PDF content with maximum original fidelity.

Architecture: keep `AudioPlayer` as the single transport owner; introduce explicit domain models for audio/book/reader anchors and chapter progress; keep EPUB, playable and embedded-segment indices separate and convert only through tested resolvers. Keep sentence timing for highlighting, never use it as book progress.

## Acceptance contract

- Complete MP3 continues after Home and iPhone lock.
- Interruption, route change and media-services reset leave state coherent and recoverable.
- Segment streaming does not silently stop when the five-item queue is exhausted; it buffers, resumes or exposes a diagnostic state.
- Now Playing primary title is the book; chapter is secondary metadata.
- Widget state reflects play/pause/chapter/progress and does not lose rapid commands.
- Progress has two visibly distinct meanings: interactive seconds scrubber for current chapter and segmented book-level chapter progress.
- Reader → Player and Player → Reader agree on EPUB chapter, page/scroll ratio and sentence anchor.
- “Tocar daqui” appears, has a stable accessibility identifier and starts at sentence/ratio.
- EPUB images render and can zoom; EPUB typography/CSS/layout are preserved by default. PDF remains page-faithful rather than reflowed.
- Final validation occurs on a physical iPhone; snapshots/accessibility alone are insufficient.

## Phase 0 — Baseline and evidence

Files: `ios/EpubToMp3/project.yml`, entitlements, `EpubToMp3App.swift`, existing tests.

1. Record clean `git status`, device identifier, build scheme and current test baseline.
2. Add a reproducible device checklist: complete MP3 Home/lock, segmented conversion Home/lock, AirPods route change, widget commands, Reader tap, “Tocar daqui”, EPUB image/font fixture.
3. Add semantic diagnostics for `tap.received`, `tap.ignored.link`, `tap.ignored.transition`, `tap.action.*`, audio session events and queue starvation.
4. Commit: `test: establish audio-reader device baseline`.

## Phase 1 — Background audio and interruption recovery

Files: `AudioPlayer.swift`, `EpubToMp3App.swift`, audio/background tests.

1. RED: tests for interruption begin/end, route change, media-services reset, failed session configuration retry, and state reconciliation (`isPlaying` vs `AVQueuePlayer.rate`).
2. GREEN: register/remove observers with lifecycle ownership; only mark `audioSessionConfigured` after successful configuration; rebuild/reconfigure after reset; preserve user intent and pause only when policy requires it.
3. RED/GREEN: device test complete MP3 after Home/lock and after phone/Siri/AirPods events.
4. Do not claim segmented background playback yet; that is Phase 2.
5. Commit: `fix(ios): recover background audio session and interruptions`.

## Phase 2 — Segment-mode semantic position and starvation

Files: `AudioPlayer.swift`, `SegmentBacklog.swift`, `AudioPlayer*Tests.swift`.

1. RED: for a 100-second chapter split into 20-second segments, assert position/duration/progress at 10s, 50s and 75s; assert seek crosses to the correct segment; assert remaining time uses chapter duration, not current segment duration.
2. GREEN: maintain explicit `segmentChapterDuration`, cumulative base, current segment-relative position and chapter-relative seek mapping. Clamp progress to 0...1.
3. RED/GREEN: queue-starvation tests for backlog exhaustion, unavailable next segment, cancellation and retry/diagnostic state.
4. Decide persistence policy for segment files: promote required resume data out of temporary storage or explicitly rebuild safely.
5. Device test: start conversion, lock before chapter completion, let five-item buffer exhaust, verify continued playback or visible recoverable state.
6. Commit: `fix(ios): normalize segmented chapter playback position`.

## Phase 3 — Now Playing and widget source of truth

Files: `AudioPlayer.swift`, `WidgetDataSync.swift`, widget extension, `EpubToMp3App.swift`, lock-screen/widget tests.

1. RED: `makeNowPlayingInfo()` must set primary title to book title; chapter must be secondary and testable. Preserve author/artwork.
2. GREEN: choose Apple metadata fields so the system displays the book first; do not rely on album title alone.
3. RED/GREEN: assert App Group book ID, chapter, play state, timing and progress use one consistent key contract. Remove standard/App Group split where it causes drift.
4. Replace boolean widget intents with an ordered command envelope/counter/UUID so rapid toggles/skips are not coalesced. Keep cold-launch recovery.
5. Define whether `openAppWhenRun` is acceptable; prefer native background behavior where supported, with a documented fallback for suspended cold launch.
6. Add widget-side backward skip if product approval confirms it.
7. Device test foreground/background/locked widget commands, two rapid toggles, two rapid skips and cold launch.
8. Commit: `fix(ios): synchronize widget and Now Playing metadata`.

## Phase 4 — Chapter-level book progress

Create: `ios/EpubToMp3/EpubToMp3/Models/BookChapterProgress.swift`.

Modify: `JobSnapshot.swift`, `MiniPlayerBar.swift`, `FullPlayerSheet.swift`, `PlayerReaderView.swift` as needed.

Tests: new `BookChapterProgressTests.swift`, `MiniPlayerBarTests.swift`, snapshot/UI tests.

1. RED: pure model tests for ordering, sparse indices, completed/running/queued/failed, ratio fallback to chars, clamping, missing URL, weighted overall progress and EPUB↔playable highlighting.
2. GREEN: derive from raw `chapterProgress`, not only `playableChapters`.
3. Render a segmented book bar with chapter-weighted widths and accessibility values. Keep current-chapter seconds scrubber separate and interactive.
4. Ensure segment timing never feeds the book-level bar.
5. Add conversion and playback screenshots with chapters of unequal sizes.
6. Commit: `feat(ios): show chapter-level audiobook progress`.

## Phase 5 — Reader ↔ Player anchor correctness

Files: `ReaderCoordinator.swift`, `PlayerReaderView.swift`, `InstantReaderView.swift`, `ReaderView.swift`, `AudioPlayer.swift`, `InstantReaderIndexMapper.swift`.

1. RED: PlayerReader navigation (`jumpTo`, advance, retreat) must call `readerCoordinator.setChapter`; chapter changes clear stale ratio/sentence.
2. GREEN: centralize all index conversion; remove manual `index - 1`, `?? 0` and ambiguous fallback paths.
3. RED/GREEN: scrolling publishes chapter, offset ratio and sentence anchor; paginated mode keeps a single coherent anchor snapshot.
4. RED/GREEN: every sentence ID emitted by `SyncEngine` resolves to a rendered `SentenceSpan`; map backend segment IDs explicitly when they differ.
5. Add policy/test for non-playable TOC chapters: no silent jump to chapter 0. Choose explicit unavailable-audio state or a visible resolution rule.
6. Add tests for malformed/out-of-order `outputs[]` so ordinal output is not falsely treated as EPUB index.
7. Commit: `fix(ios): unify Reader and Player anchors`.

## Phase 6 — “Tocar daqui” and touch routing

Files: `PlayDivergenceDialog.swift`, `InstantReaderView.swift`, `PlayerReaderView.swift`, `ReaderView.swift`, `AttributedPageView.swift`, `TextKitPageView.swift`.

1. RED: UI/source-contract tests require stable IDs for divergence dialog and “Tocar daqui” in both hosts.
2. GREEN: make the action visible and deterministic in paginated, scrolling and page-curl modes; preserve link precedence.
3. Add explicit hit-testing contracts: invisible overlays are absent or `allowsHitTesting(false)`; one tap owner per UIKit surface; transition debounce reports ignored taps rather than silently swallowing them.
4. Test center/left/right taps, links, chrome hidden, repeated taps during curl, selection action floater and Mini Player controls.
5. Device-test screenshots plus accessibility tree; verify visual overlay does not block the text surface.
6. Commit: `fix(ios): make reader touch actions visible and deterministic`.

## Phase 7 — EPUB/PDF asset contract, fidelity and images

Files: `EbookFulltext.swift`, `EpubHtmlRenderer.swift`, `EpubReaderRenderingSettings.swift`, `MacEpubParser.swift`, `EpubFallbackParser.swift`, `ZipReader.swift`, parser/server JSON contracts, `AttributedPageView.swift`, `TextKitPageView.swift` and tests.

Important finding: the current renderer supports only `data:` URI images. Normal EPUB resources such as `images/foo.jpg` are dropped because the chapter contract has no document base path, manifest or asset bytes. This phase must fix the data contract before changing presentation.

1. RED: real EPUB fixtures with relative images, subdirectories, `../`, percent-encoded paths, SVG/PNG/JPEG/GIF, `alt`, dimensions, embedded fonts, headings, lists, links, tables, margins, line-height, italics and page breaks.
2. GREEN: evolve the fulltext contract with deduplicated resources (`id`, `href`, media type, bounded bytes/base64 or local cache reference, dimensions and alt), source base path/manifest and font metadata. Mirror the contract through Python parser, server/cache, Swift parser/fallback and Android entrypoint where applicable.
3. RED/GREEN: resolve `src`/`xlink:href` against the document path and manifest, normalize URL encoding and `../`, substitute images before the HTML importer and reinsert bounded `NSTextAttachment` values. Preserve aspect ratio, CSS dimensions and accessibility alt text; retain the prepared tap-to-zoom model.
4. RED/GREEN: add `.woff2`, avoid font basename collisions, and validate that the CSS family resolves to the registered font. Keep unsupported obfuscation as an explicit diagnostic.
5. Change typography policy from unconditional clamps to explicit modes: `preserveOriginal` by default, `safeReadable` only when selected, and `userOverride` for reader controls. In original mode preserve CSS alignment, colors, heading scale, paragraph spacing, indentation, line-height and page-break rules.
6. Add structural fixtures/tests for nested lists, tables, figure/figcaption, pre/code, links, SVG fallback and forced page breaks. If exact HTML/CSS fidelity exceeds TextKit, evaluate `WKWebView`-based paginated EPUB rendering as the high-fidelity backend, keeping TextKit as fallback.
7. For PDF, enforce the separate `PDFView` path end-to-end: preserve fixed pages, images, fonts and physical layout; never reflow PDF text through the EPUB reader. Add a routing test and a scanned-PDF diagnostic/OCR policy test.
8. Add snapshots at iPhone SE/large iPhone/iPad, portrait/landscape and light/dark/sepia, plus physical-device visual checks. Document unavoidable EPUB reflow/platform limits: pixel-perfect Kindle equivalence cannot be guaranteed for arbitrary HTML/CSS, while PDF can remain page-faithful.
9. Commit: `feat(ios): preserve ebook assets and original reader fidelity`.

## Phase 8 — Integration and physical-device gate

1. Run focused XCTest targets after every phase.
2. Run full iOS tests/build without downloading extra simulator runtimes.
3. Install on the physical iPhone.
4. Execute Home/lock/interruption/widget/Reader/touch/progress/image/font/layout matrix in portrait, landscape, Dynamic Type, VoiceOver, Reduce Motion and dark mode.
5. Capture logs/screenshots and compare EPUB index, playable index, segment chapter and visible chapter simultaneously.
6. Only then mark the plan complete.

## Grill — decisions Pietro must answer before implementation

1. Quando o áudio ainda está convertendo e o buffer acaba: prefere esperar silenciosamente, mostrar “gerando próximo trecho”, ou oferecer fallback de voz?
2. No Now Playing, o formato desejado é `Livro` como título + `Capítulo` secundário, sem misturar os dois no título?
3. A barra por capítulos deve ficar na Mini Player, no player completo, ou nos dois?
4. A barra de capítulo deve representar conversão, reprodução, ou mostrar as duas camadas visualmente separadas?
5. Ao tocar um capítulo sem áudio no TOC: bloquear, abrir leitura sem áudio, ou iniciar o capítulo reproduzível anterior?
6. No reader, toque no centro deve continuar alternando chrome? Toque esquerdo/direito deve virar página ou permanecer chrome-only?
7. “Tocar daqui” deve aparecer por toque simples na frase, toque longo, botão flutuante, ou todos?
8. Ao áudio avançar, o Reader deve seguir automaticamente sempre, ou parar de seguir após qualquer gesto manual até “Acompanhar áudio”?
9. Imagens devem abrir zoom em tela cheia ao toque ou somente aparecer no fluxo do texto?
10. Para EPUB, “100% original” significa priorizar CSS/layout mesmo que a fonte fique pequena, ou permitir uma adaptação mínima para legibilidade no iPhone?
11. Para capítulos enormes, aceita paginação reflowável do Kindle/Books, ou quer preservar quebras de página físicas quando existirem?
12. O bloqueio deve manter também a conversão/TTS em andamento, ou apenas continuar tocando áudio já produzido?
