# In-book search

The iOS text reader uses the existing Find dialog and opens the first matching
passage, beginning with the displayed chapter and wrapping once through the
source chapter order. Queries are literal, case- and diacritic-insensitive.
Blank input is disabled; missing matches have explicit feedback. PDF/comic
surfaces report that this text search is unavailable. A prepared-only warm
reader searches its displayed chapter and explains that scope.

`ReaderBookSearch` scans immutable source strings outside the main actor.
`ReaderSearchPresentation` owns request cancellation, prompt dismissal and
book/load/chapter identity. Before selecting a candidate, it resolves the range
again against the actual rendered UTF-16 text. Source offsets never select a
range in differently formatted text. Failed candidates restore the original
chapter and raw offset; cancelled or replaced requests cannot navigate or save.

`ReaderTextViewport.reveal` moves the outer `UIScrollView`; the disabled inner
`UITextView` only owns selection. Paginated results use the glyph-aware
canonical page containing the first matching line; continuous reading uses
its measured line offset. Existing viewport transition ownership is unchanged.

## Verification

Run `mise run apple:foundation:test` for matching, wrapping, UTF-16 coordinates,
Portuguese diacritics, empty input and cancellation. Native XCTest coverage in
`ReaderSearchScopeTests` and `ReaderSearchViewportTests` checks rendered ranges,
outer scrolling, page clipping, no results, cancellation and book replacement.
UIKit execution and the seeded-reader app journey are deferred to the final
native campaign; Foundation results do not establish native layout acceptance.
The required SE1/iOS 15.5 acceptance remains blocked by Simulator quarantine.

References: [Apple text search ranges](https://developer.apple.com/documentation/foundation/nsstring/range(of:options:)),
[UITextView selection](https://developer.apple.com/documentation/uikit/uitextview/selectedrange),
and [HIG Searching](https://developer.apple.com/design/human-interface-guidelines/searching).
