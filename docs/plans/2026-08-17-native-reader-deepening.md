# Native reader deepening plan

## Goal

Deepen the three recurring UIKit reader seams without changing product behavior:
the final text viewport, content surface mounting, and root presentation
transaction.

## Agreed shape

### 1. Reader text viewport — first

Create concrete `ReaderTextViewport`. Its interface accepts the mounted text
surface and committed viewport geometry, applies final text presentation, and
returns only observable viewport facts: page state, scroll extent, clipping,
and oversized-fragment fallback.

It owns TextKit measurement, application of `ReaderPaginatedTextLayout.Result`,
overflow guards, and page-indicator facts. It does not own anchor capture,
transition ordering, raw-offset restoration, canonical page-boundary decisions,
or reader loading/navigation. Those responsibilities remain at the existing
seams defined by the reader ADRs.

Replace `ReaderPaginationWiringTests` source inspection in the same commit with
XCTest behavior at this seam. The evidence gate covers:

1. Chrome toggles restore the exact raw viewport offset.
2. Paginated text exposes no partially visible glyph.
3. Only explicit page turns use canonical offsets.
4. An oversized protected fragment selects scrolling fallback.

### 2. Reader content surface — second

Deepen concrete `ReaderContentSurface` so it owns text, comic, and PDF mounting;
stable constraints; visibility; interaction; and PDF view disposal. Its interface
mounts a content source and reports the active surface kind.

`BookOpenScreenController` remains the reading-flow owner. There is one UIKit
adapter, so this adds no protocol. XCTest crosses the mounting seam rather than
the caller's constraint arrays.

### 3. Root reader presentation — third

Extract a concrete root-owned presentation coordinator only after the first two
changes settle. It receives `ReaderPresentationState` plus availability facts and
executes one transaction for chrome, mini player, full player, anchors, and final
geometry. `IOSRootContainer` remains the UIKit adapter and presentation owner
required by the viewport-transition ADR.

Tests cross this seam through loading, immersive chrome, mini player, and final
geometry. There is one root adapter, so this adds no protocol.

## Correction map

### Correction candidates

None currently qualify. The only reader symptom note,
`docs/bugs/reader-forward-crossing-black-flash.md`, explicitly lacks device
instrumentation and describes retired SwiftUI files, not the active UIKit seam.
It must not be treated as a current defect.

### Hypotheses to investigate

| Hypothesis | Evidence | Experiment | Passing result |
|---|---|---|---|
| Legacy forward chapter-crossing flash may still exist | Old report lacks device evidence and predates the UIKit reader | On an authorized device, cross a substantive chapter boundary in paginated mode, then make five paced forward and five reverse turns at default and small native-serif fonts | No blank/black frame; monotonic chapter/page state; `clippedLineCount = 0` |
| Flicker telemetry cannot prove a regression | The three counters render/reset but have no increment path; UI tests only assert zero | Add an injection-only native test seam that emits each event and assert its accessibility summary | Each injected event reports one; normal interactions can then supply evidence |
| Final viewport facts are not jointly proven through root presentation | Unit tests cover transition/layout independently; UI coverage is separate | Run the native LOTR matrix: default/small font, chrome visible/hidden, repeated/interrupted toggles, forward/back turns | Exact raw-offset round trip; canonical explicit turns; zero clipping; correct fallback |
| Content-surface lifecycle may leak on real format switches | XCTest covers PDF → text but not an import/switch/reopen sequence for all active kinds | On device, switch supported image content, PDF, and EPUB; reopen each | Exactly one active surface; inactive constraints/interactions disabled; no leftover PDF view |
| Root transaction can violate single vertical ownership | State facts are unit-tested while concrete constraints span three UIKit owners | UI test loading → reader → immersive → full player → dismiss/library | One active vertical owner; final geometry precedes TextKit probe; no overlap |

Turn a hypothesis into a correction candidate only when its experiment produces a
reproducible symptom. File that candidate as a GitHub Issue with the symptom,
affected invariant, reproduction, and proposed regression test.

## Sequence and non-goals

Implement one seam per change. Do not mix a behavior fix, a new reader feature,
or a cross-platform abstraction into these refactors. Do not add a protocol
unless two real adapters require the seam.

## Implementation record — 2026-08-18

All three planned concrete seams are now implemented:

1. `ReaderTextViewport` owns final TextKit presentation, canonical-page facts,
   clipping masks, the oversized-fragment fallback, and the trailing inset
   used only to preserve a raw chrome-transition offset.
2. `ReaderContentSurface` owns installation and mutually exclusive mounting of
   text, comic, and PDF surfaces. Its PDF path cancels stale preparation work
   and uses `PdfReadingPageNormalizer` to display scanned two-up PDFs as
   upright logical pages.
3. `ReaderRootPresentationCoordinator` owns the root presentation state,
   vertical reader ownership, and transition invalidation when a reader closes.

The scanned-PDF path keeps a separate visual derivative in the system cache;
the first reader open normalizes each physical spread, while warm opens reopen
the cached logical PDF. OCR text and audio conversion remain owned by the
Python parser/cache path.

The permanent XCTest coverage crosses each new seam: viewport pagination and
fallback, content-surface switching, root transition cancellation, and scanned
PDF orientation/page ordering. The Python regression suite covers scanner OCR,
OCR-cache reuse, parser extraction failures, empty-parser conversion failure,
and cache metadata identity.
