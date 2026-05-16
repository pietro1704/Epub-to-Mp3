import Foundation
import CoreGraphics

/// Pure-logic page splitter for the reader. Lives in `Services/`
/// (not `Views/`) so the SPM target can compile + test it without
/// SwiftUI.
///
/// The algorithm is intentionally naive: estimate a `chars/page`
/// budget from the page geometry, font size, and line spacing, then
/// walk `spans` adding sentences to the current page until the next
/// one would push us over. Page breaks always land at a sentence
/// boundary so we never cut a word.
enum Paginator {

    /// Splits `spans` into pages. Empty input → empty result.
    ///
    /// - Parameter headerHeight: estimated height of the chapter-title
    ///   header shown only on page 0. The first page's line budget is
    ///   reduced accordingly so text never overflows the visible area.
    static func paginate(
        spans: [SentenceSpan],
        pageSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: Double,
        columnWidth: CGFloat,
        margin: Double,
        headerHeight: CGFloat = 0
    ) -> [String] {
        guard !spans.isEmpty else { return [] }
        let usableWidth = max(200, min(columnWidth, pageSize.width - 2 * CGFloat(margin)))
        let usableHeight = max(120, pageSize.height - 120)
        let charsPerLine = max(20, Int(usableWidth / max(6, fontSize * 0.55)))
        let lineHeight = fontSize + CGFloat(lineSpacing)
        let linesPerPage = max(8, Int(usableHeight / lineHeight))
        let charsPerPage = max(400, charsPerLine * linesPerPage)

        let firstPageHeaderLines = headerHeight > 0 ? max(0, Int(ceil(headerHeight / lineHeight))) : 0
        let charsFirstPage = max(200, (linesPerPage - firstPageHeaderLines) * charsPerLine)

        var pages: [String] = []
        var current = ""
        var isFirstPage = true
        let budget = { isFirstPage ? charsFirstPage : charsPerPage }
        for span in spans {
            let next = current.isEmpty ? span.text : current + "\n\n" + span.text
            if next.count > budget(), !current.isEmpty {
                pages.append(current)
                current = span.text
                isFirstPage = false
            } else {
                current = next
            }
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }
}
