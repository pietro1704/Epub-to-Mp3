import Foundation

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Measures the complete height of a paginated text container.
///
/// A reader page is only a viewport over the text view. Measuring with the
/// viewport-sized text container makes TextKit stop laying out after page one,
/// which in turn clips the remaining chapter when that height becomes an Auto
/// Layout constraint.
@MainActor
enum ReaderPaginatedTextLayout {
    /// The complete, glyph-safe pagination decision for one final viewport.
    /// Presentation code may apply this result, but must not recreate page
    /// boundaries by re-enumerating TextKit line fragments.
    struct Input {
        let layoutManager: NSLayoutManager
        let textContainer: NSTextContainer
        let topInset: CGFloat
        let bottomInset: CGFloat
        let pageHeight: CGFloat

        init(
            layoutManager: NSLayoutManager,
            textContainer: NSTextContainer,
            topInset: CGFloat,
            bottomInset: CGFloat,
            pageHeight: CGFloat
        ) {
            self.layoutManager = layoutManager
            self.textContainer = textContainer
            self.topInset = max(0, topInset)
            self.bottomInset = max(0, bottomInset)
            self.pageHeight = max(0, pageHeight)
        }

        var verticalInset: CGFloat { topInset + bottomInset }
    }

    /// One TextKit line made safe for every glyph it renders. `contentRect`
    /// is expressed in scroll-content coordinates, after the UITextView top
    /// inset has been applied; `containerRect` remains in TextKit's native
    /// container coordinates for callers that need its glyph range.
    struct ProtectedFragment: Equatable {
        let glyphRange: NSRange
        let containerRect: CGRect
        let contentRect: CGRect
    }

    struct ClippingReport {
        let intersectingFragments: [ProtectedFragment]
        let clippedFragments: [ProtectedFragment]

        var clippedLineCount: Int { clippedFragments.count }
    }

    struct Result {
        let contentHeight: CGFloat
        let canonicalPageOffsets: [CGFloat]
        let protectedFragments: [ProtectedFragment]
        /// A fragment taller than the usable page cannot satisfy normal
        /// pagination. The caller must use its explicit non-clipping fallback
        /// instead of pretending a canonical page boundary is valid.
        let oversizedFragment: ProtectedFragment?
        let pageHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat

        /// The caller must present this chapter continuously because a whole
        /// protected fragment cannot fit in the physical paginated viewport.
        var requiresScrollingFallback: Bool { oversizedFragment != nil }

        func pageIndex(at contentOffset: CGFloat) -> Int {
            guard canonicalPageOffsets.count > 1 else { return 0 }
            let epsilon: CGFloat = 0.5
            return canonicalPageOffsets.lastIndex(where: { $0 <= contentOffset + epsilon }) ?? 0
        }

        func pageOffset(for pageIndex: Int) -> CGFloat {
            canonicalPageOffsets[min(max(0, pageIndex), canonicalPageOffsets.count - 1)]
        }

        func clippingReport(at contentOffset: CGFloat) -> ClippingReport {
            let viewport = readingViewport(at: contentOffset)
            let intersecting = protectedFragments.filter { $0.contentRect.intersects(viewport) }
            return ClippingReport(
                intersectingFragments: intersecting,
                clippedFragments: intersecting.filter { !viewport.contains($0.contentRect) }
            )
        }

        /// The bottom slice of the viewport which must be covered as a
        /// defense-in-depth presentation measure when a non-canonical offset
        /// exposes part of the following protected fragment. This is never a
        /// substitute for a clean `clippingReport` on a canonical page.
        func bottomOverflowMaskRange(at contentOffset: CGFloat) -> ClosedRange<CGFloat>? {
            let viewport = readingViewport(at: contentOffset)
            let report = clippingReport(at: contentOffset)
            guard report.clippedFragments.contains(where: { $0.contentRect.maxY > viewport.maxY }) else {
                return nil
            }
            guard let lastCompleteBottom = report.intersectingFragments
                .filter({ viewport.contains($0.contentRect) })
                .map(\.contentRect.maxY)
                .max(), lastCompleteBottom < viewport.maxY - 0.5 else {
                return nil
            }
            return lastCompleteBottom...viewport.maxY
        }

        private func readingViewport(at contentOffset: CGFloat) -> CGRect {
            CGRect(
                x: 0,
                y: contentOffset + topInset,
                width: .greatestFiniteMagnitude,
                height: max(0, pageHeight - topInset - bottomInset)
            )
        }
    }

    /// Calculates all pagination facts from one TextKit pass. The caller must
    /// invoke this only after the viewport has final, committed geometry.
    static func layout(_ input: Input) -> Result {
        let textContainer = input.textContainer
        let currentSize = textContainer.size
        textContainer.size = CGSize(
            width: max(currentSize.width, 1),
            height: .greatestFiniteMagnitude
        )
        input.layoutManager.ensureLayout(for: textContainer)
        let glyphRange = input.layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else {
            return Result(
                contentHeight: max(input.pageHeight, 1),
                canonicalPageOffsets: [0],
                protectedFragments: [],
                oversizedFragment: nil,
                pageHeight: input.pageHeight,
                topInset: input.topInset,
                bottomInset: input.bottomInset
            )
        }

        var fragments: [ProtectedFragment] = []
        input.layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
            let glyphRect = input.layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: textContainer)
            let containerRect = lineRect.union(glyphRect)
            guard containerRect.height > 0 else { return }
            fragments.append(ProtectedFragment(
                glyphRange: lineGlyphRange,
                containerRect: containerRect,
                contentRect: containerRect.offsetBy(dx: 0, dy: input.topInset)
            ))
        }
        guard let lastFragment = fragments.last else {
            return Result(
                contentHeight: max(input.pageHeight, 1),
                canonicalPageOffsets: [0],
                protectedFragments: [],
                oversizedFragment: nil,
                pageHeight: input.pageHeight,
                topInset: input.topInset,
                bottomInset: input.bottomInset
            )
        }

        let usableHeight = max(0, input.pageHeight - input.verticalInset)
        let naturalHeight = ceil(lastFragment.containerRect.maxY + input.verticalInset)
        // Reserve a full final viewport from the final protected-fragment
        // start, so UIScrollView cannot clamp that canonical start into the
        // previous line.
        let boundaryHeight = ceil(lastFragment.contentRect.minY - input.topInset + input.pageHeight)
        let contentHeight = max(input.pageHeight, max(naturalHeight, boundaryHeight))
        let oversized = fragments.first(where: { $0.containerRect.height > usableHeight + 0.5 })

        guard input.pageHeight > input.verticalInset, !fragments.isEmpty else {
            return Result(
                contentHeight: contentHeight,
                canonicalPageOffsets: [0],
                protectedFragments: fragments,
                oversizedFragment: oversized,
                pageHeight: input.pageHeight,
                topInset: input.topInset,
                bottomInset: input.bottomInset
            )
        }

        var offsets: [CGFloat] = [0]
        var pageStart: CGFloat = 0
        var firstFragment = 0
        let epsilon: CGFloat = 0.5
        while firstFragment < fragments.count {
            while firstFragment < fragments.count,
                  fragments[firstFragment].contentRect.maxY <= pageStart + input.topInset + epsilon {
                firstFragment += 1
            }
            guard firstFragment < fragments.count else { break }

            let pageLimit = pageStart + input.pageHeight - input.bottomInset
            var nextFragment = firstFragment
            while nextFragment < fragments.count,
                  fragments[nextFragment].contentRect.maxY <= pageLimit + epsilon {
                nextFragment += 1
            }
            guard nextFragment < fragments.count else { break }

            let nextOffset = fragments[nextFragment].contentRect.minY - input.topInset
            let safeOffset = nextOffset > pageStart + epsilon
                ? nextOffset
                : pageStart + input.pageHeight
            offsets.append(safeOffset)
            pageStart = safeOffset
            firstFragment = nextFragment
        }
        return Result(
            contentHeight: contentHeight,
            canonicalPageOffsets: offsets,
            protectedFragments: fragments,
            oversizedFragment: oversized,
            pageHeight: input.pageHeight,
            topInset: input.topInset,
            bottomInset: input.bottomInset
        )
    }

    static func measuredContentHeight(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        verticalInset: CGFloat,
        topInset: CGFloat = 0,
        pageHeight: CGFloat
    ) -> CGFloat {
        layout(Input(
            layoutManager: layoutManager,
            textContainer: textContainer,
            topInset: topInset,
            bottomInset: max(0, verticalInset - topInset),
            pageHeight: pageHeight
        )).contentHeight
    }

    /// Scroll offsets that begin each viewport on a full TextKit line
    /// fragment. Fixed-height offsets split a line between two reader pages;
    /// these offsets preserve the entire line at the start of the next page.
    static func pageOffsets(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        verticalInset: CGFloat,
        topInset: CGFloat = 0,
        pageHeight: CGFloat
    ) -> [CGFloat] {
        layout(Input(
            layoutManager: layoutManager,
            textContainer: textContainer,
            topInset: topInset,
            bottomInset: max(0, verticalInset - topInset),
            pageHeight: pageHeight
        )).canonicalPageOffsets
    }
}
