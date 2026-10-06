# Reader text viewport presentation

**Status:** Accepted

`ReaderTextViewport` is the concrete deep module for final UIKit text
presentation after a reader geometry commit. It owns TextKit measurement,
application of the glyph-aware layout result, scroll extent, overflow guards,
page indication, and observable clipping/fallback facts; `BookOpenScreenController`
owns the reading flow. `ReaderViewportTransition` remains the seam for anchor
capture, transition ordering, and raw-offset restoration, while
`ReaderPaginatedTextLayout` remains the seam for canonical offsets and protected
fragments. This deliberately avoids making a protocol for the single UIKit
adapter and stops these presentation rules leaking through the screen
controller's lifecycle.
