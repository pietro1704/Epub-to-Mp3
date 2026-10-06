# UI/UX Audit — Native iOS/macOS App

Static review by a UI, accessibility, and UX specialist. Scope: reader,
library, playback, mini-player, conversion/jobs, settings, loading/error
states, localization, accessibility, and iOS/macOS parity.

No source code, tests, builds, or commits were changed by the auditor.

## P1 — High impact

### 1. Pagination is estimated instead of based on rendered content

**Confirmed.** `BookOpenScreenController.swift` estimates pages from
`chapter.text.count / 1200` and moves by `scrollView.bounds.height`.

Impact: page counts can be wrong; lateral taps may skip or repeat content, and
the end of a chapter may become unreachable when font, margins, HTML, images,
Dynamic Type, or device width changes.

Recommended fix: paginate the rendered content with TextKit/
`NSLayoutManager`/`NSTextContainer`, or another layout-backed paginator.

### 2. Changing typography can lose the current reading position

**Confirmed.** Reader settings call `showChapter(self.selectedChapter)`, while
position restoration is guarded by `hasRestoredInitialPosition` and is intended
for initial loading.

Impact: changing font, theme, margins, or layout can return the user to the
start of the chapter.

Recommended fix: preserve a semantic character/sentence position before
re-rendering and restore it after layout, rather than relying only on a
vertical fraction.

### 3. Reader gestures can conflict

**Confirmed.** The reader installs tap recognizers on both `UIScrollView` and
`UITextView`, a pan recognizer on the whole view, and allows simultaneous
recognition broadly.

Impact: selecting text may toggle chrome; horizontal swipes can be interpreted
as scrolling, page turns, and chapter navigation at once.

Recommended fix: arbitrate recognizers by pair and mode:

- center tap → chrome;
- edge tap → page;
- horizontal pan → page/chapter;
- vertical pan → scrolling mode only.

### 4. Center tap area is large and has no accessible equivalent

**Confirmed.** The center region covers roughly 40% of width and height and
the action is not exposed as an accessibility control.

Impact: accidental chrome changes; VoiceOver, keyboard, and Switch Control
users cannot discover or restore the controls.

Recommended fix: expose “Show/hide reader controls” as an accessible button
with label, hint, trait, and state.

### 5. Immersive mode does not fully update accessibility focus

**Confirmed.** The mini-player and reader toolbar are hidden, but no
`UIAccessibility.layoutChangedNotification` or `screenChangedNotification` is
posted.

Impact: VoiceOver may retain focus on a hidden control or fail to announce that
the reading surface now occupies the full screen.

Recommended fix: announce the layout change and move focus to the content or
the controls toggle.

## P2 — Medium impact

### 6. Reader text does not fully honor Dynamic Type

**Confirmed.** The text view enables adjustment but uses absolute
`.systemFont(ofSize:)`; `EpubHtmlRenderer` also uses absolute sizes.

Impact: accessibility text sizes can overflow or invalidate pagination.

Recommended fix: use `UIFontMetrics.scaledFont` and re-paginate on category
changes.

### 7. Entire chapter text is one accessibility element

**Confirmed.** `textView.isAccessibilityElement = true`.

Impact: long chapters become one large VoiceOver block with poor navigation by
paragraph, heading, or sentence.

Recommended fix: preserve semantic structure or provide paragraph-level
accessibility navigation where feasible.

### 8. Reader toolbar image buttons lack explicit labels

**Confirmed.** TOC, search, and appearance buttons have identifiers/images but
no explicit accessibility labels.

Recommended labels: “Table of contents”, “Search in book”, and “Reader
settings”. Localize them.

### 9. Library add/filter controls lack explicit labels

**Confirmed.** Add and sort/filter controls rely on images/UIKit heuristics.

Impact: VoiceOver announcements can vary by OS version.

Recommended fix: add explicit labels and hints.

### 10. Library menu contains hardcoded English

**Confirmed.** `LibraryScreenController.swift` uses `UIMenu(title: "Tags", ...)`.

Impact: pt-BR/es interfaces contain mixed language.

Recommended fix: add a localized `library.tags` key.

### 11. macOS reader settings contain hardcoded Portuguese

**Confirmed.** `MacReaderViewController.swift` contains literals such as
“Fonte”, “Tema”, “Layout”, “Margens”, “Kerning”, and “Colunas”.

Impact: macOS does not follow the selected app language.

Recommended fix: route every label through `L10n.string(...)`.

### 12. macOS reader typography does not adapt to accessibility scaling

**Confirmed.** The reader uses fixed sizes such as 13 and 24 plus the configured
point size, without explicit system scaling.

Impact: poor readability in small windows and for low-vision users.

Recommended fix: support system font scaling and adaptive layout.

### 13. iOS reader toolbar truncates long book titles

**Confirmed.** The title is one line with `byTruncatingMiddle` beside fixed-size
buttons.

Impact: long book titles are hard to identify on small iPhones and with larger
text settings.

Recommended fix: allow two lines or move the title into its own area.

### 14. Mini-player/safe-area layout needs device validation

**Needs runtime validation.** The mini-player is anchored to the safe-area
bottom and the reader to its top. Validate home-indicator devices, landscape,
iPad multitasking, and transitions between hidden/visible states.

### 15. Reader loading state has no cancel/retry action

**Confirmed.** Loading shows cover, spinner, and status but no cancel, retry, or
fallback action.

Impact: a stalled parse/file access can leave the user without an exit path.

Recommended fix: provide Cancel; on failure provide Retry and Back to library.

## P3 — Lower impact / consistency

### 16. Page indicator lacks semantic accessibility text

**Confirmed.** It has an identifier but no explicit label/value.

Recommended fix: announce “Page, 1 of 10” rather than only “1 of 10”.

### 17. macOS playback controls have inconsistent accessibility descriptions

**Confirmed.** Some SF Symbol buttons use nil descriptions.

Recommended fix: centralize button configuration with title, description, state,
and key equivalent.

### 18. macOS keyboard navigation is incomplete

**Confirmed.** Custom keyboard handling exists for reader text, but there is no
equivalent evidence for toolbar, TOC, search, settings, or mini-player.

Recommended fix: provide predictable focus order and key equivalents for core
actions.

### 19. macOS reader settings popover may clip at small sizes

**Confirmed.** The popover is fixed at approximately `220 × 360` while holding
many vertical options.

Recommended fix: use a scrollable form or dynamic popover sizing.

### 20. macOS product title is hardcoded

**Confirmed.** `MacAppKitRootController.swift` uses
`NSTextField(labelWithString: "Epub-to-Mp3")`.

Impact: minor branding/localization inconsistency.

## Runtime/device validation still required

- Dynamic Type at XXXL and text clipping;
- actual theme contrast;
- gesture arbitration across iOS versions;
- VoiceOver announcements in library and reader;
- focus after hiding/restoring chrome;
- iPad Split View and Stage Manager;
- minimum macOS window size;
- rotation during pagination;
- opening another book while audio is playing;
- external keyboard, trackpad, and Switch Control;
- iPhone/iPad landscape safe areas;
- performance with large chapters and PDFs;
- pagination with complex EPUB fonts/HTML.

## Recommended implementation order

1. Replace character-count pagination with layout-backed pagination.
2. Separate and arbitrate reader gestures.
3. Make immersive chrome accessible and restorable by VoiceOver.
4. Fix Dynamic Type and position restoration after typography changes.
5. Add explicit accessibility labels to all controls.
6. Remove hardcoded strings and fix macOS localization parity.
7. Validate iPad/macOS, small windows, and loading/error states on devices.
