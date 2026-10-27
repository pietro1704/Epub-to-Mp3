import Foundation

enum ReaderBookSearch {
    struct Chapter: Sendable {
        let position: Int
        let text: String
    }

    static func firstRange(query: String, in text: String) -> NSRange? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let range = (text as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        return range.location == NSNotFound ? nil : range
    }

    static func candidates(query: String, chapters: [Chapter], startingAt position: Int,
                           isCancelled: () -> Bool = { false }) -> [Int] {
        guard !chapters.isEmpty else { return [] }
        let start = chapters.firstIndex { $0.position == position } ?? 0
        let order = Array(chapters[start...]) + Array(chapters[..<start])
        var matches: [Int] = []
        for chapter in order {
            guard !isCancelled() else { return [] }
            if firstRange(query: query, in: chapter.text) != nil { matches.append(chapter.position) }
        }
        return isCancelled() ? [] : matches
    }
}
