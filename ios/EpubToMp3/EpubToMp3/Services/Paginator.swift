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
        // Vertical: subtract padding (48), footer (30), nav chrome (20)
        let usableHeight = max(120, pageSize.height - 98)
        let charWidth = max(6, fontSize * 0.55)
        let charsPerLine = max(15, Int(usableWidth / charWidth))
        let lineHeight = fontSize + CGFloat(lineSpacing) + 2
        let linesPerPage = max(5, Int(usableHeight / lineHeight))
        // 85% safety factor — SwiftUI wraps slightly earlier than monospace math
        let charsPerPage = max(200, Int(Double(charsPerLine * linesPerPage) * 0.85))

        let headerLines = headerHeight > 0
            ? max(0, Int(ceil(headerHeight / lineHeight))) + 1 : 0
        let charsFirstPage = max(150, Int(Double(charsPerLine * max(3, linesPerPage - headerLines)) * 0.85))

        let all = spans.map(\.text).joined(separator: "\n\n")
        return splitText(all, normalBudget: charsPerPage, firstBudget: charsFirstPage)
    }

    private static func splitText(_ text: String, normalBudget: Int, firstBudget: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var pages: [String] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            let budget = pages.isEmpty ? firstBudget : normalBudget
            if remaining.count <= budget {
                pages.append(String(remaining).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }
            let cutEnd = remaining.index(remaining.startIndex, offsetBy: budget)
            let candidate = remaining[remaining.startIndex..<cutEnd]
            // Find last paragraph break, sentence end, or word break
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
                remaining = remaining[cutEnd...]
            }
        }
        return pages.filter { !$0.isEmpty }
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
