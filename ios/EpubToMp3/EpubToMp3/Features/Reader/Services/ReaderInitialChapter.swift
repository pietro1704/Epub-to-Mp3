import Foundation

enum ReaderInitialChapter {
    /// Resolves persisted reader progress against the payload that was just
    /// loaded. An EPUB with no readable chapters is an error state, never a
    /// blank reader surface.
    static func index(selectedChapter: Int, chapterCount: Int) -> Int? {
        guard chapterCount > 0 else { return nil }
        return min(max(selectedChapter, 0), chapterCount - 1)
    }

    /// Skips cover/title boilerplate on a first open while retaining the
    /// persisted index for returning readers.
    static func firstSubstantiveIndex(in chapters: [EbookFulltext.Chapter]) -> Int {
        chapters.firstIndex { ($0.charCount ?? $0.text.count) >= 1_000 } ?? 0
    }
}
