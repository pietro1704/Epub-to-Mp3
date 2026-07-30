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
        pageHeight: CGFloat
    ) -> CGFloat {
        let currentSize = textContainer.size
        textContainer.size = CGSize(
            width: max(currentSize.width, 1),
            height: .greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        return max(pageHeight, ceil(textHeight + verticalInset))
    }

    /// Scroll offsets that begin each viewport on a full TextKit line
    /// fragment. Fixed-height offsets split a line between two reader pages;
    /// these offsets preserve the entire line at the start of the next page.
    static func pageOffsets(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        verticalInset: CGFloat,
        pageHeight: CGFloat
    ) -> [CGFloat] {
        guard pageHeight > verticalInset else { return [0] }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else { return [0] }

        var lines: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            guard usedRect.height > 0 else { return }
            lines.append(usedRect)
        }
        guard !lines.isEmpty else { return [0] }

        let usableHeight = pageHeight - verticalInset
        let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height + verticalInset)
        let maximumScrollOffset = max(0, contentHeight - pageHeight)
        var offsets: [CGFloat] = [0]
        var pageStart: CGFloat = 0
        var firstLine = 0
        let epsilon: CGFloat = 0.5

        while firstLine < lines.count {
            while firstLine < lines.count, lines[firstLine].maxY <= pageStart + epsilon {
                firstLine += 1
            }
            guard firstLine < lines.count else { break }

            let pageLimit = pageStart + usableHeight
            var nextLine = firstLine
            while nextLine < lines.count, lines[nextLine].maxY <= pageLimit + epsilon {
                nextLine += 1
            }
            guard nextLine < lines.count else { break }

            let nextOffset = lines[nextLine].minY
            // The outer scroll view cannot go beyond its content height. Keep
            // a final reachable offset instead of publishing an offset that
            // UIKit will silently clamp, which used to make the final reader
            // page appear as a blank or a repeated earlier page.
            if nextOffset >= maximumScrollOffset - epsilon {
                if maximumScrollOffset > pageStart + epsilon {
                    offsets.append(maximumScrollOffset)
                }
                break
            }
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
