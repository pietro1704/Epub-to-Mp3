import Foundation

enum ConversionChapterSelection {
    enum SelectionError: Error { case invalid }

    static func validateBounds(start: Int32, end: Int32) throws {
        if start == -1 && end == -1 { return }
        guard start >= 0, end >= -1, end == -1 || end >= start else { throw SelectionError.invalid }
    }

    static func resolve(start: Int32, end: Int32, chapterCount: Int) throws -> ClosedRange<Int>? {
        try validateBounds(start: start, end: end)
        if start == -1 && end == -1 { return nil }
        let first = Int(start)
        guard chapterCount > 0, first < chapterCount else { throw SelectionError.invalid }
        let last = end == -1 ? chapterCount - 1 : Int(end)
        guard last < chapterCount else { throw SelectionError.invalid }
        return first...last
    }

    static func parse(_ input: String) throws -> (start: Int32, end: Int32) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (-1, -1) }
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { throw SelectionError.invalid }
        let values = try parts.map { part -> Int32 in
            let digits = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let value = Int32(digits) else { throw SelectionError.invalid }
            return value
        }
        let start = values[0]
        let end = values.count == 1 ? start : values[1]
        guard end >= start else { throw SelectionError.invalid }
        return (start, end)
    }
}
