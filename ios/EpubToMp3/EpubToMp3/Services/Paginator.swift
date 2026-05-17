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
        headerHeight: CGFloat = 0
    ) -> [String] {
        guard !spans.isEmpty else { return [] }
        let usableWidth = max(200, min(columnWidth, pageSize.width - 2 * CGFloat(margin)))
        // Deduct vertical padding (24pt top + 24pt bottom) + page footer (~28pt)
        let usableHeight = max(120, pageSize.height - 76)
        // San Francisco average glyph width is ~0.44em for body text
        let charWidth = max(6, fontSize * 0.44)
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

    /// Count chars with paragraph gaps weighted as full lines.
    private static func weightedCount(_ text: some StringProtocol, charsPerLine: Int) -> Int {
        var count = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\n" {
                    count += charsPerLine
                    i = text.index(after: next)
                    continue
                }
                count += charsPerLine
            } else {
                count += 1
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
            // Walk forward counting weighted chars until we exceed budget
            let cutIndex = findCutPoint(in: remaining, budget: budget, charsPerLine: charsPerLine)
            let candidate = remaining[remaining.startIndex..<cutIndex]

            if let paraBreak = candidate.range(of: "\n\n", options: .backwards) {
                pages.append(String(remaining[remaining.startIndex..<paraBreak.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = remaining[paraBreak.upperBound...]
            } else if let sentenceEnd = findLastSentenceBreak(in: candidate) {
                pages.append(String(remaining[remaining.startIndex...sentenceEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                let next = remaining.index(after: sentenceEnd)
                remaining = remaining[next...]
            } else if let space = candidate.range(of: " ", options: .backwards) {
                pages.append(String(remaining[remaining.startIndex..<space.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = remaining[space.upperBound...]
            } else {
                pages.append(String(candidate).trimmingCharacters(in: .whitespacesAndNewlines))
                remaining = remaining[cutIndex...]
            }
        }
        return pages.filter { !$0.isEmpty }
    }

    private static func findCutPoint(in text: Substring, budget: Int, charsPerLine: Int) -> String.Index {
        var weight = 0
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "\n" {
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "\n" {
                    weight += charsPerLine
                    if weight >= budget { return i }
                    i = text.index(after: next)
                    continue
                }
                weight += charsPerLine
            } else {
                weight += 1
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
