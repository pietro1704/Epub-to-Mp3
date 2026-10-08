import Foundation

enum ConversionChapterSelection {
    enum SelectionError: Error { case invalid }

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
