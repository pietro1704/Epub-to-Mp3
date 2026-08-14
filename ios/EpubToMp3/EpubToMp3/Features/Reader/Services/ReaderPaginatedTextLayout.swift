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
    static func measuredContentHeight(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        verticalInset: CGFloat,
        topInset: CGFloat = 0,
        pageHeight: CGFloat
    ) -> CGFloat {
        let currentSize = textContainer.size
        textContainer.size = CGSize(
            width: max(currentSize.width, 1),
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lastLineStart: CGFloat = 0
        var lastLineBottom: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
            let glyphRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: textContainer)
            let protectedRect = lineRect.union(glyphRect)
            lastLineStart = max(lastLineStart, protectedRect.minY)
            lastLineBottom = max(lastLineBottom, protectedRect.maxY)
        }
        // A final page may start at the last complete line fragment. Reserve
        // the remaining viewport as trailing whitespace so UIKit never clamps
        // that offset into the middle of the preceding line.
        let naturalHeight = ceil(lastLineBottom + verticalInset)
        // TextKit line coordinates start inside UITextView's top inset,
        // whereas UIScrollView offsets start at the view's content edge.
        // Reserve that translation for the final page too, otherwise UIKit
        // clamps its final offset into the last rendered line.
        let boundaryHeight = ceil(lastLineStart + topInset + pageHeight)
        return max(pageHeight, max(naturalHeight, boundaryHeight))
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
        guard pageHeight > verticalInset else { return [0] }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else { return [0] }

        var lines: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
            // `usedRect` excludes part of a line's typographic leading for
            // some fonts. Paging from it can put the next line a few points
            // above the viewport, visibly cutting its glyphs. Page against
            // the complete line fragment instead.
            let glyphRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: textContainer)
            let protectedRect = lineRect.union(glyphRect)
            guard protectedRect.height > 0 else { return }
            lines.append(protectedRect)
        }
        guard !lines.isEmpty else { return [0] }

        // Reserve the text view's top/bottom padding when choosing the last
        // line for a page so the next line does not enter the bottom inset.
        let resolvedTopInset = min(max(0, topInset), verticalInset)
        let usableHeight = pageHeight - verticalInset
        var offsets: [CGFloat] = [0]
        var pageStart: CGFloat = 0
        var firstLine = 0
        let epsilon: CGFloat = 0.5

        while firstLine < lines.count {
            let visibleTextStart = pageStart - resolvedTopInset
            while firstLine < lines.count, lines[firstLine].maxY <= visibleTextStart + epsilon {
                firstLine += 1
            }
            guard firstLine < lines.count else { break }

            let pageLimit = pageStart + usableHeight
            var nextLine = firstLine
            while nextLine < lines.count, lines[nextLine].maxY <= pageLimit + epsilon {
                nextLine += 1
            }
            guard nextLine < lines.count else { break }

            // Convert from TextKit's container coordinate to the scroll
            // coordinate. Without the top inset here, the preceding line
            // remains partially visible at the top and a line is cut at the
            // bottom of each subsequent page.
            let nextOffset = lines[nextLine].minY + resolvedTopInset
            // Every page begins at a complete line. Do not replace the final
            // boundary with an arbitrary maximum scroll offset: that can land
            // inside a line fragment and visibly crop its glyphs.
            // A single oversized accessibility line cannot fit into one
            // viewport. Advance normally in that exceptional case rather
            // than looping forever or skipping its text.
            let safeOffset = nextOffset > pageStart + epsilon
                ? nextOffset
                : pageStart + pageHeight
            offsets.append(safeOffset)
            pageStart = safeOffset
            firstLine = nextLine
        }
        return offsets
    }
}
