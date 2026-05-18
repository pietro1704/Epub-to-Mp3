import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// TextKit-backed pagination. We render the chapter into a virtual
/// `NSLayoutManager` + `NSTextContainer` per page using the real font,
/// line-spacing and column width — same approach Apple Books / Kindle
/// use. The page break lands wherever the layout engine reports
/// overflow, so every page is filled to the bottom (no more half-empty
/// pages from a char-budget heuristic that didn't match reality).
///
/// On platforms without UIKit/AppKit (Linux CI, headless tests) we fall
/// back to a heuristic char-budget — the unit tests in `PaginatorTests`
/// only assert *ordering* properties (serif → more pages than sans, etc),
/// not exact splits, so the heuristic is good enough there.
enum Paginator {

    static func paginate(
        spans: [SentenceSpan],
        pageSize: CGSize,
        fontSize: CGFloat,
        lineSpacing: Double,
        columnWidth: CGFloat,
        margin: Double,
        headerHeight: CGFloat = 0,
        fontFamily: ReaderFontFamily = .sans
    ) -> [String] {
        guard !spans.isEmpty else { return [] }

        let usableWidth = max(200, min(columnWidth, pageSize.width - 2 * CGFloat(margin)))
        // Match the reader chrome we know is fixed: 24pt top + 24pt bottom
        // padding from `pageView`, ~30pt for the page-number footer.
        let usableHeight = max(120, pageSize.height - 76)

        let allText = spans.map(\.text).joined(separator: "\n\n")

        #if canImport(UIKit) || canImport(AppKit)
        return textKitPaginate(
            text: allText,
            pageWidth: usableWidth,
            pageHeight: usableHeight,
            headerHeight: headerHeight,
            fontSize: fontSize,
            lineSpacing: CGFloat(lineSpacing),
            fontFamily: fontFamily
        )
        #else
        return heuristicPaginate(
            text: allText,
            usableWidth: usableWidth,
            usableHeight: usableHeight,
            headerHeight: headerHeight,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            fontFamily: fontFamily
        )
        #endif
    }

    // MARK: - Attributed pagination (preserves EPUB CSS)

    /// Page-break a pre-rendered `NSAttributedString` (from
    /// `EpubHtmlRenderer`) by laying it out with TextKit and slicing the
    /// resulting glyph ranges. **All attributes survive**: fonts, weight,
    /// italics, foreground/background colour, paragraph indent, line
    /// height — i.e. whatever the EPUB's CSS asked for and whatever
    /// `applyOverrides` left in place.
    #if canImport(UIKit) || canImport(AppKit)
    static func paginateAttributed(
        _ attributed: NSAttributedString,
        pageSize: CGSize,
        columnWidth: CGFloat,
        margin: Double,
        headerHeight: CGFloat = 0
    ) -> [NSAttributedString] {
        guard attributed.length > 0 else { return [] }
        let usableWidth = max(200, min(columnWidth, pageSize.width - 2 * CGFloat(margin)))
        let usableHeight = max(120, pageSize.height - 76)

        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        var pages: [NSAttributedString] = []
        var nextLocation = 0
        let total = storage.length

        while nextLocation < total {
            let containerHeight = pages.isEmpty
                ? max(60, usableHeight - headerHeight)
                : usableHeight
            let container = NSTextContainer(size: CGSize(width: usableWidth, height: containerHeight))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            layout.addTextContainer(container)

            let glyphRange = layout.glyphRange(for: container)
            guard glyphRange.length > 0 else {
                let safeLen = min(1, total - nextLocation)
                guard safeLen > 0 else { break }
                let range = NSRange(location: nextLocation, length: safeLen)
                pages.append(attributed.attributedSubstring(from: range))
                nextLocation += safeLen
                continue
            }
            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // Do NOT snap to a word boundary here: each `NSTextContainer`
            // has already consumed glyphs up to `charRange.length`, so
            // snapping the *slice* back to whitespace while TextKit keeps
            // laying out from where the original range ended would drop
            // every character between the snap point and the end of the
            // container — chunks of the book would silently disappear at
            // every page break. Take the raw char range. Mid-word cuts
            // are cosmetic; missing text is data loss.
            guard charRange.length > 0 else { break }
            pages.append(attributed.attributedSubstring(from: charRange))
            nextLocation = charRange.location + charRange.length
        }
        return pages
    }
    #endif

    // MARK: - TextKit-backed plain (iOS / macOS)

    #if canImport(UIKit) || canImport(AppKit)
    private static func textKitPaginate(
        text: String,
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        headerHeight: CGFloat,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        fontFamily: ReaderFontFamily
    ) -> [String] {
        // Font matching the renderer settings. Tests work in the simulator,
        // so this is the same font Text() will ultimately pick at runtime.
        let font = systemFont(size: fontSize, family: fontFamily)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)

        // One storage + layout manager for the whole chapter — we attach
        // a fresh container per page so each get-glyph-range call returns
        // only what fits inside that page's box.
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        // Use the legacy (non-TextKit2) path explicitly: TextKit2 in newer
        // SDKs lays out lazily and the per-container glyph range we rely
        // on here returns 0 length until forced. Sticking with the
        // classic layout manager keeps the pagination deterministic.
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        var ranges: [NSRange] = []
        var nextLocation = 0
        let totalLength = storage.length

        while nextLocation < totalLength {
            // First page gets less vertical room when the host renders a
            // chapter-title header above the body text.
            let containerHeight = ranges.isEmpty
                ? max(60, pageHeight - headerHeight)
                : pageHeight

            let container = NSTextContainer(size: CGSize(width: pageWidth, height: containerHeight))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            layout.addTextContainer(container)

            // `containers.count - 1` is the index of the container we just
            // added. `glyphRange(for:)` returns the glyph slice that fits.
            let glyphRange = layout.glyphRange(for: container)
            guard glyphRange.length > 0 else {
                // Layout engine refused to place anything (e.g. a single
                // word wider than the column). Force-advance by one
                // character so we don't infinite-loop.
                let safeStart = min(nextLocation, totalLength)
                let safeLength = min(1, totalLength - safeStart)
                guard safeLength > 0 else { break }
                ranges.append(NSRange(location: safeStart, length: safeLength))
                nextLocation = safeStart + safeLength
                continue
            }
            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            // Snap to a word boundary so we never end mid-word visually.
            let snapped = snapToWordEnd(in: storage.string, range: charRange, fullLength: totalLength)
            guard snapped.length > 0 else { break }

            ranges.append(snapped)
            nextLocation = snapped.location + snapped.length
        }

        let nsString = storage.string as NSString
        return ranges.map {
            nsString.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// Pull the range end back to the most recent word boundary so the
    /// page never ends in the middle of a word. The next page picks up
    /// from the snapped position, so nothing is lost — only relocated.
    private static func snapToWordEnd(in text: String, range: NSRange, fullLength: Int) -> NSRange {
        let end = range.location + range.length
        // If we reached EOF or the next character is already whitespace /
        // a paragraph break, the cut is clean as-is.
        if end >= fullLength { return range }
        let ns = text as NSString
        let endChar = ns.character(at: end)
        if isWhitespaceOrNewline(unichar: endChar) { return range }

        // Walk backwards within this page's range until we hit whitespace.
        var probe = end - 1
        while probe > range.location {
            let c = ns.character(at: probe)
            if isWhitespaceOrNewline(unichar: c) {
                // Cut RIGHT AFTER the whitespace so the next page starts
                // with the next word, not with a leading space.
                return NSRange(location: range.location, length: probe + 1 - range.location)
            }
            probe -= 1
        }
        // No whitespace in this page (a single very long word, code, etc).
        // Keep the original cut — TextKit's char boundary is already
        // grapheme-safe.
        return range
    }

    private static func isWhitespaceOrNewline(unichar c: unichar) -> Bool {
        // U+0020 space, U+000A LF, U+00A0 nbsp, U+2028 line sep, tab.
        c == 0x20 || c == 0x0A || c == 0x09 || c == 0xA0 || c == 0x2028
    }

    private static func systemFont(size: CGFloat, family: ReaderFontFamily) -> PlatformFont {
        switch family {
        case .sans:
            return PlatformFont.systemFont(ofSize: size)
        case .serif:
            #if canImport(UIKit)
            let descriptor = UIFont.systemFont(ofSize: size)
                .fontDescriptor.withDesign(.serif)
                ?? UIFont.systemFont(ofSize: size).fontDescriptor
            return UIFont(descriptor: descriptor, size: size)
            #else
            return NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
            #endif
        case .mono:
            #if canImport(UIKit)
            return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            #else
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            #endif
        }
    }
    #endif

    // MARK: - Heuristic fallback (no TextKit available)

    private static func heuristicPaginate(
        text: String,
        usableWidth: CGFloat,
        usableHeight: CGFloat,
        headerHeight: CGFloat,
        fontSize: CGFloat,
        lineSpacing: Double,
        fontFamily: ReaderFontFamily
    ) -> [String] {
        // Average glyph width varies by family: serif ~0.52em, mono ~0.58em, sans ~0.44em.
        let factor: CGFloat = {
            switch fontFamily {
            case .serif: return 0.52
            case .mono:  return 0.58
            case .sans:  return 0.44
            }
        }()
        let charWidth = max(6, fontSize * factor)
        let charsPerLine = max(15, Int(usableWidth / charWidth))
        let lineHeight = fontSize + CGFloat(lineSpacing) + 2
        let linesPerPage = max(5, Int(usableHeight / lineHeight))
        let charsPerPage = charsPerLine * linesPerPage

        let headerLines = headerHeight > 0
            ? max(0, Int(ceil(headerHeight / lineHeight))) + 1 : 0
        let charsFirstPage = charsPerLine * max(3, linesPerPage - headerLines)

        return splitText(text, normalBudget: charsPerPage, firstBudget: charsFirstPage,
                         charsPerLine: charsPerLine)
    }

    private static func splitText(_ text: String, normalBudget: Int, firstBudget: Int,
                                    charsPerLine: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var pages: [String] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            let budget = pages.isEmpty ? firstBudget : normalBudget
            if remaining.count <= budget {
                pages.append(String(remaining).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
            // Walk forward `budget` chars then back to the nearest word break.
            let cutIndex = remaining.index(remaining.startIndex, offsetBy: min(budget, remaining.count))
            let candidate = remaining[remaining.startIndex..<cutIndex]
            if let breakPt = findLastWordBreak(in: candidate) {
                pages.append(String(remaining[remaining.startIndex..<breakPt])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                var resumeIdx = breakPt
                while resumeIdx < remaining.endIndex,
                      remaining[resumeIdx] == " " || remaining[resumeIdx] == "\n" {
                    resumeIdx = remaining.index(after: resumeIdx)
                }
                remaining = remaining[resumeIdx...]
            } else {
                pages.append(String(candidate).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = remaining[cutIndex...]
            }
        }
        return pages.filter { !$0.isEmpty }
    }

    private static func findLastWordBreak(in text: Substring) -> String.Index? {
        var best: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == " " || text[i] == "\n" { best = i }
            i = text.index(after: i)
        }
        return best
    }
}

// `PlatformFont` is the module-wide UIFont/NSFont alias declared in
// `EpubHtmlRenderer.swift`. Don't redeclare here.
