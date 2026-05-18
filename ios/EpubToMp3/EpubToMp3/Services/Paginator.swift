import Foundation
import CoreGraphics

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
        // Deduct vertical padding (24pt top + 24pt bottom) + page footer (~28pt)
        let usableHeight = max(120, pageSize.height - 76)
        // Average glyph width varies by family: serif ~0.52em, mono ~0.58em, sans ~0.44em
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

        let all = spans.map(\.text).joined(separator: "\n\n")
        return splitText(all, normalBudget: charsPerPage, firstBudget: charsFirstPage,
                         charsPerLine: charsPerLine)
    }

    /// Count chars with paragraph gaps (`\n\n`) weighted as a full line
    /// break. A bare `\n` costs only the remainder of the current line
    /// (simulating a soft line break rather than a full paragraph gap).
    private static func weightedCount(_ text: some StringProtocol, charsPerLine: Int) -> Int {
        var count = 0
        var posInLine = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\n" {
                    // Paragraph break: finish current line + half-line gap
                    let remainder = charsPerLine - posInLine
                    count += remainder + charsPerLine / 2
                    posInLine = 0
                    i = text.index(after: next)
                    continue
                }
                // Bare newline: just finish the current line
                let remainder = max(1, charsPerLine - posInLine)
                count += remainder
                posInLine = 0
            } else {
                count += 1
                posInLine += 1
                if posInLine >= charsPerLine { posInLine = 0 }
            }
            i = text.index(after: i)
        }
        return count
    }

    private static func splitText(_ text: String, normalBudget: Int, firstBudget: Int,
                                    charsPerLine: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var pages: [String] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            let budget = pages.isEmpty ? firstBudget : normalBudget
            if weightedCount(remaining, charsPerLine: charsPerLine) <= budget {
                pages.append(String(remaining).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
            // Walk forward counting weighted chars until we exceed budget.
            // Break at the nearest word boundary (space, sentence end, or
            // paragraph break) WITHOUT backtracking to earlier paragraph
            // breaks — each page should be maximally full, like Apple Books.
            let cutIndex = findCutPoint(in: remaining, budget: budget, charsPerLine: charsPerLine)
            let candidate = remaining[remaining.startIndex..<cutIndex]

            if let sentenceEnd = findLastSentenceBreak(in: candidate) {
                pages.append(String(remaining[remaining.startIndex...sentenceEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                let next = remaining.index(after: sentenceEnd)
                remaining = remaining[next...]
            } else if let breakPt = findLastWordBreak(in: candidate) {
                pages.append(String(remaining[remaining.startIndex..<breakPt])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                // Skip whitespace / paragraph markers at the break point
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

    /// Find the last word-boundary position (space or paragraph break)
    /// in the candidate text. Returns the index OF the space/newline so
    /// the caller can split before it.
    private static func findLastWordBreak(in text: Substring) -> String.Index? {
        var best: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == " " || text[i] == "\n" {
                best = i
            }
            i = text.index(after: i)
        }
        return best
    }

    private static func findCutPoint(in text: Substring, budget: Int, charsPerLine: Int) -> String.Index {
        var weight = 0
        var posInLine = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\n" {
                    let remainder = charsPerLine - posInLine
                    weight += remainder + charsPerLine / 2
                    posInLine = 0
                    if weight >= budget { return i }
                    i = text.index(after: next)
                    continue
                }
                let remainder = max(1, charsPerLine - posInLine)
                weight += remainder
                posInLine = 0
            } else {
                weight += 1
                posInLine += 1
                if posInLine >= charsPerLine { posInLine = 0 }
            }
            if weight >= budget { return text.index(after: i) }
            i = text.index(after: i)
        }
        return text.endIndex
    }

    private static func findLastSentenceBreak(in text: Substring) -> String.Index? {
        var best: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "." || c == "!" || c == "?" {
                let next = text.index(after: i)
                if next >= text.endIndex || text[next] == " " || text[next] == "\n" {
                    best = i
                }
            }
            i = text.index(after: i)
        }
        return best
    }
}
