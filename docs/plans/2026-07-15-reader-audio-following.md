# Reader and Audio Following Implementation Plan

> **For Hermes:** Implement this plan task-by-task with tests and physical-device validation.

**Goal:** Make the iOS reader behave like an audiobook reader: support phrase/paragraph playback actions, persistent reader/audio continuation, automatic audio following, word highlighting, EPUB images, and Apple Books-style typography controls.

**Architecture:** Extend the existing SwiftUI reader/player coordination instead of creating a second playback state. Keep one shared reading/audio anchor, with a five-second manual-navigation cooldown before automatic following resumes. Add reader rendering capabilities at the EPUB layer (styled text and inline images); keep PDF layout immutable.

**Tech Stack:** SwiftUI, TextKit/UIKit EPUB page renderer, PDFKit, AVFoundation/AVKit, existing `AudioPlayer`, `SyncEngine`, `ReaderCoordinator`, `SentenceSpan`, `EbookFulltext`, XCTest/XCUITest.

---

## Product decisions

- Long press and double tap preserve text selection and show a floater with:
  - “Tocar desta frase”
  - “Tocar deste parágrafo”
- Phrase playback starts at the selected/tapped phrase.
- Paragraph playback starts at the first phrase in the selected paragraph.
- The Play button offers the two continuation choices when both positions are available:
  - continue from the reader/audio position where the user stopped;
  - continue from the audio position.
- If only one position exists, Play starts directly.
- Reader and audio positions are normally one shared position. A manual reader move creates temporary divergence.
- Manual divergence lasts five seconds. Audio keeps playing; after the cooldown the reader returns to the audio's current phrase/page/chapter/scroll position.
- While divergent, show “Acompanhar”. Tapping it immediately returns to audio, resumes following, and hides the button.
- Audio following updates phrase, word, page, chapter, and scrolling position automatically.
- Word highlighting uses real word timing when available and estimated timing within the active sentence otherwise.
- EPUB paginated and scrolling modes support inline images, scaled to screen width while preserving aspect ratio, with tap-to-zoom.
- EPUB supports “Usar fonte do livro” plus bundled/custom fonts. Font choice preserves bold, italic, headings, and other EPUB styles.
- EPUB exposes font family, size, line spacing, margins, and alignment controls. Repagination preserves the approximate reading position.
- EPUB reader supports a pinch gesture to increase or decrease font size, with clamped limits and debounced repagination while preserving the approximate reading position.
- PDF keeps its original layout and fonts; EPUB typography controls are disabled for PDF.

---

## Implementation tasks

### 1. Map current reader/player contracts

Inspect `PlayerReaderView`, `InstantReaderView`, `ReaderView`, `TextKitPageView`, `SyncEngine`, `AudioPlayer`, `ReaderCoordinator`, `EbookFulltext`, and existing reader/player tests. Document the current coordinate systems, sentence timing, page persistence, and EPUB/PDF rendering boundaries before changing behavior.

**Verification:** Add or update source-contract tests only where an existing contract is missing; run focused Swift host tests.

### 2. Model shared reading/audio position and cooldown

Unify reader and player anchors while preserving the existing manual-divergence behavior. Add explicit state for:

- shared chapter/sentence/page/scroll anchor;
- whether the reader is manually divergent;
- five-second cooldown deadline;
- visibility of the “Acompanhar” action;
- following enabled/disabled state.

Cancel/reset timers on pause, teardown, book changes, and explicit “Acompanhar”. Ensure a manual chapter change keeps rendering the selected chapter during cooldown while audio continues in the old chapter.

**Tests:** position precedence, five-second expiry, pause/reset, chapter divergence, explicit follow action.

### 3. Implement Play continuation alert

Update the reader transport Play action to offer the two continuation choices only when both positions are meaningful. Start directly when only one position exists. Do not prioritize a previously tapped phrase over saved positions unless the user explicitly chooses the phrase floater action.

**Tests:** both-position alert, single-position direct start, no-position default, selected phrase not implicitly overriding Play.

### 4. Add phrase/paragraph action floater

Preserve long-press and double-tap selection. Resolve the selected range to:

- the exact `SentenceSpan` for “Tocar desta frase”;
- the containing paragraph and its first `SentenceSpan` for “Tocar deste parágrafo”.

Support TextKit EPUB pages, scrolling EPUB text, and PDF text hit-testing where extracted text can be mapped back to audio spans. Avoid triggering system selection handles as the only action; the custom floater must be available alongside selection.

**Tests:** phrase resolution, paragraph resolution, boundary ranges, paginated/scrolling hit testing, PDF mapping fallback.

### 5. Add automatic page/chapter/scroll following

When audio is playing and following is enabled, map the active sentence/word anchor to the current reader representation:

- paginated EPUB: switch page/chapter as needed;
- scrolling EPUB: scroll to the active sentence/word;
- PDF: navigate to the corresponding page without changing PDF layout.

Manual page turns disable following and start the five-second cooldown. After expiry, follow the latest audio position, not the position that existed when the manual turn happened.

**Tests:** page changes, chapter crossings, scrolling targets, manual override, cooldown return, paused audio.

### 6. Implement word-level highlighting

Use real word timing metadata when supplied by the audio/sync pipeline. Where only sentence timing exists, estimate the active word using proportional word timing with punctuation-aware tokenization. Render a contrast-safe highlight that adapts to light/dark mode and accessibility contrast settings.

**Tests:** real timing precedence, estimated timing, punctuation/empty tokens, theme colors, sentence transitions.

### 7. Render EPUB inline images

Carry EPUB image nodes through the parsed/rendered representation into both paginated and scrolling reader modes. Render images at available content width while preserving aspect ratio. Add a tap target that presents a zoomable image viewer with dismiss gesture.

**Tests:** image order, width constraint, aspect ratio, missing/invalid image fallback, paginated/scrolling rendering, zoom presentation.

### 8. Add Apple Books-style EPUB typography controls

Extend reader settings with:

- “Usar fonte do livro”;
- bundled fonts such as Georgia and SF;
- registered custom fonts;
- font size;
- pinch-to-zoom font scaling;
- line spacing;
- margins;
- alignment.

Apply family changes without stripping EPUB traits: bold, italic, headings, links, lists, and other existing styles remain styled. Debounce settings updates and preserve the nearest text offset through repagination. Pinch scaling must use clamped font-size limits, avoid changing font size for PDF, and debounce repagination so a continuous pinch does not thrash layout.

Render the font selector with each font name displayed in its own font. Disable these controls for PDF while leaving PDF layout unchanged.

**Tests:** original-font mode, alternative/custom font mode, trait preservation, settings persistence, pinch scaling/clamping/debounce, position preservation, PDF control disabling.

### 9. Add regression and UI coverage

Update Swift unit/source-contract tests and add focused XCUITests for:

- Play continuation alert;
- long press/double tap floater;
- “Acompanhar” visibility and return;
- automatic cross-page/cross-chapter following;
- EPUB image zoom;
- font selector and typography settings.

### 10. Validate on device

Run focused Swift host tests, the full project test suite where applicable, build the iOS target for the physical iPhone without downloading simulator runtimes, install, launch, and exercise reader/audio flows on device. Inspect screenshots for image, font, selection/floater, highlight, and bottom/top chrome behavior.

**Definition of done:** tests pass, physical-device build/install/launch succeeds, and the reader/player flow is manually verified on the iPhone.

---

## Acceptance checklist

- [ ] Long press and double tap select text and expose phrase/paragraph playback.
- [ ] Play continuation behavior follows the saved-position rules.
- [ ] Five-second manual-navigation cooldown works across pages and chapters.
- [ ] “Acompanhar” appears only during divergence and returns to live audio.
- [ ] EPUB paginated/scrolling and PDF follow the active audio location.
- [ ] Word highlight uses real or estimated timing.
- [ ] EPUB images render responsively and open zoomed.
- [ ] EPUB font/style/settings controls work and preserve position.
- [ ] Pinch gesture increases/decreases EPUB font size with clamping and debounced repagination.
- [ ] PDF layout/font remains unchanged and EPUB controls are disabled.
- [ ] Focused tests, full relevant tests, and physical-device validation pass.
