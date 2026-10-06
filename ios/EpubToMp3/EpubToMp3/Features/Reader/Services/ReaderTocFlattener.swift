import Foundation

/// One row in a reader's chapter list — shared by `BookOpenScreenController`
/// (iOS) and `MacReaderViewController` (macOS) so the TOC-hierarchy display
/// logic exists in exactly one place.
struct ReaderTocRow: Equatable {
    let title: String
    let level: Int
    /// 0-based index into `EbookFulltext.chapters`, already converted from
    /// the server's 1-based `TocEntry.chapterIndex`. `nil` for a TOC entry
    /// that doesn't resolve to a parsed chapter (e.g. an endnote container
    /// dropped as zero-length).
    let chapterIndex: Int?
}

enum ReaderTocFlattener {
    /// Builds display rows from `fulltext.toc` (indented by level) when
    /// present; falls back to a flat list of chapters — matching the
    /// pre-TOC behaviour exactly — when the parser didn't resolve a TOC
    /// (or the book has none).
    static func rows(toc: [EbookFulltext.TocEntry]?, chapters: [EbookFulltext.Chapter]) -> [ReaderTocRow] {
        if let toc, !toc.isEmpty {
            return flatten(toc, level: 0)
        }
        return chapters.enumerated().map { offset, chapter in
            ReaderTocRow(title: chapter.displayTitle, level: 0, chapterIndex: offset)
        }
    }

    private static func flatten(_ entries: [EbookFulltext.TocEntry], level: Int) -> [ReaderTocRow] {
        entries.flatMap { entry -> [ReaderTocRow] in
            let row = ReaderTocRow(
                title: entry.title, level: level, chapterIndex: entry.chapterIndex.map { $0 - 1 }
            )
            return [row] + flatten(entry.children, level: level + 1)
        }
    }
}
