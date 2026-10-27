# EPUB link previews and footnotes

The iOS reader opens local EPUB links in a scrollable native sheet. Opening or
dismissing the preview leaves the reading chapter and raw offset unchanged.
Only **Go to position** mounts the destination chapter and reveals its rendered
anchor through `ReaderTextViewport`; chapter-only links open the chapter start.
External web/mail/telephone links retain system handling.

## Responsibilities

- `ReaderLinkResolver.internalTarget` resolves the archive-relative source path
  and decoded fragment, preserving EPUB path/identifier case. A missing fragment
  never silently becomes chapter start; duplicate chapter identities fail closed.
- `EpubAnchorFragment` selects nested element content with Foundation's XML
  parser, retaining inline markup and paragraph structure. Empty or number-only
  anchor tags use their readable containing block (or next readable sibling).
  Inputs are limited to 2 MiB and 128 element levels; external entity resolution
  is disabled. Common HTML void tags and punctuation entities are normalized.
  Malformed markup or duplicate IDs fail closed instead of guessing a location.
- `ReaderLinkPresentation` renders the preview with the book CSS, registered
  fonts/resources and current reader overrides. A readable plain-text fallback
  is used when importing that fragment fails. An extracted plain-text footnote
  can still be displayed when its separate source document is absent from the
  chapter catalog; it offers no invented navigation destination.
- `ReaderAnchorRange` maps the preview back to actual rendered UTF-16 text,
  collapsing importer whitespace. Missing or ambiguous matches reject navigation
  and restore the original chapter/raw offset. Raw source offsets are not used.
- `ReaderLinkPreviewController` owns scrolling, dismissal and the explicit action.
  A closed preview rejects delayed actions; a successful action is consumed once.
  Internal links inside a preview cannot escape through UIKit's URL opener.

Go actions verify current book, load generation and original chapter before
changing state. Prepared-only warm readers can preview their available chapter
without treating its source ordinal as zero. Other unavailable chapters report
an explicit destination error. Fixed-layout PDF/comic annotations are outside
this EPUB link path.

## Verification

`mise run apple:foundation:test` covers nested HTML, malformed/duplicate/missing
anchors, empty/named anchors, path case, same/cross-document fragments, external
schemes, Unicode/UTF-16 coordinates, whitespace and overlapping ambiguous text.
`ReaderLinkPreviewTests` adds native UIKit coverage for scrollable complete notes,
preview-only position preservation, explicit/duplicate actions, missing targets,
book replacement, dismissal and prepared-only chapter identity.

Foundation: 174 tests, 15 skipped, zero failures. Native UIKit compilation and
execution, source-style fidelity and the visible seeded-reader/device journey
remain deferred to the final campaign. No red-before native execution is claimed.
The required SE1/iOS 15.5 runtime acceptance remains blocked by Simulator quarantine.

References: [Apple HIG Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets),
[UITextView](https://developer.apple.com/documentation/uikit/uitextview), and
[XMLParser external entities](https://developer.apple.com/documentation/foundation/xmlparser/shouldresolveexternalentities).
