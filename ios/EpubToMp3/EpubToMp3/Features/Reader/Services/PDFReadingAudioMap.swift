import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Maps PDFKit character positions to the exact Rust narration chapter axis.
/// Matching is ordered across physical pages, so repeated paragraphs cannot
/// resolve to an earlier occurrence. Unmapped/scanned pages fail closed.
struct PDFReadingAudioMap: Sendable {
    struct Chapter: Decodable, Sendable {
        let index: String
        let name: String
        let sourcePath: String
        let text: String
        func title(_ names: [Int: String]) -> String { Int(index).flatMap { names[$0] } ?? name }
        var startPage: Int? {
            Int(sourcePath.replacingOccurrences(of: "page-", with: "")).map { $0 - 1 }.flatMap { $0 >= 0 ? $0 : nil }
        }
    }
    struct Metadata: Decodable {
        let chapters: [Chapter]
        let skippedPages: Int?
        enum CodingKeys: String, CodingKey { case chapters, skippedPages = "skipped_pages" }
    }
    struct Anchor: Equatable {
        let chapterIndex: Int
        let sourceScalarOffset: Int
        fileprivate let chapterLength: Int
        var ratio: Double { Double(sourceScalarOffset) / Double(chapterLength) }
    }
    struct Page: Sendable {
        let chapterIndex: Int
        let displayOffsets: [Int]
        let chapterOffsets: [Int]
        let speechOffsets: [Int]
        let chapterLength: Int
    }
    let chapters: [Chapter]
    let pages: [Int: Page]
    /// Pages with nothing to narrate, such as an image cover or a blank page.
    private let textlessPages: Set<Int>
    /// Text-less pages that Rust left out of the narration.
    let skippedPages: Int
    /// Provisional chapter lengths for the playback timeline while narration is still streaming.
    var chapterEstimates: [Int: TimeInterval] {
        chapters.enumerated().reduce(into: [:]) { $0[$1.offset] = ChapterPlaybackTimeline.estimate(text: $1.element.text) }
    }
    var skippedPagesNotice: String? {
        guard skippedPages > 0 else { return nil }
        return skippedPages == 1 ? L10n.string("convert.pdfPagesSkipped.one")
            : L10n.string("convert.pdfPagesSkipped.many", skippedPages)
    }

    init(metadata: Data, pageTexts: [String]) throws {
        let decoded = try JSONDecoder().decode(Metadata.self, from: metadata)
        chapters = decoded.chapters
        skippedPages = decoded.skippedPages ?? 0
        var mapped: [Int: Page] = [:]
        for (chapterIndex, chapter) in chapters.enumerated() {
            guard let start = chapter.startPage, pageTexts.indices.contains(start) else { continue }
            let end = min(chapters.dropFirst(chapterIndex + 1).first?.startPage ?? pageTexts.count, pageTexts.count)
            guard end > start else { continue }
            let canonical = Self.normalized(chapter.text)
            var cursor = 0
            for pageIndex in start..<end {
                guard cursor <= canonical.text.length,
                      let found = Self.locate(pageTexts[pageIndex], in: canonical.text, from: cursor)
                        ?? Self.locateByLines(pageTexts[pageIndex], in: canonical.text, from: cursor)
                else { continue }
                mapped[pageIndex] = Page(chapterIndex: chapterIndex, displayOffsets: found.displayOffsets,
                    chapterOffsets: found.narration.map { canonical.offsets[$0] },
                    speechOffsets: found.narration.map { canonical.scalarOffsets[$0] },
                    chapterLength: chapter.text.unicodeScalars.count)
                cursor = found.end
            }
        }
        pages = mapped
        textlessPages = Set(pageTexts.indices.filter { Self.normalized(pageTexts[$0]).text.length == 0 })
    }

    func anchor(page: Int, character: Int = 0) -> Anchor? {
        guard let mapped = pages[page], mapped.chapterLength > 0,
              !mapped.displayOffsets.isEmpty else { return nil }
        let index = mapped.displayOffsets.firstIndex(where: { $0 >= max(0, character) }) ?? mapped.displayOffsets.count - 1
        return Anchor(chapterIndex: mapped.chapterIndex, sourceScalarOffset: mapped.speechOffsets[index],
                      chapterLength: mapped.chapterLength)
    }

    /// Where "listen" starts for the page on screen: textless pages are passed over, while a page
    /// whose text does not match the narration still fails closed.
    func playbackAnchor(page: Int, character: Int = 0) -> Anchor? {
        var target = page
        while textlessPages.contains(target) { target += 1 }
        return anchor(page: target, character: target == page ? character : 0)
    }

    func displayRange(chapter: Int, range: NSRange) -> (page: Int, range: NSRange)? {
        guard range.location >= 0, range.length > 0 else { return nil }
        for (index, page) in pages.sorted(by: { $0.key < $1.key }) where page.chapterIndex == chapter {
            let matches = page.chapterOffsets.indices.filter { NSLocationInRange(page.chapterOffsets[$0], range) }
            guard let first = matches.first, let last = matches.last else { continue }
            let start = page.displayOffsets[first], end = page.displayOffsets[last] + 1
            return (index, NSRange(location: start, length: end - start))
        }
        return nil
    }

    func displayLocation(chapter: Int, character: Int) -> (page: Int, character: Int)? {
        // Estimated offsets may land on whitespace or punctuation, which the
        // alignment skips. Continue from the next mapped glyph in the chapter.
        var lastLocation: (page: Int, character: Int)?
        for (index, page) in pages.sorted(by: { $0.key < $1.key }) where page.chapterIndex == chapter {
            if let next = page.chapterOffsets.firstIndex(where: { $0 >= character }) {
                return (index, page.displayOffsets[next])
            }
            if let last = page.displayOffsets.last { lastLocation = (index, last) }
        }
        return lastLocation
    }

    /// Where a page sits in the narration: for each matched unit, its page and narration positions.
    private struct Placement {
        var displayOffsets: [Int]
        var narration: [Int]
        var end: Int
    }

    private static func locate(_ page: String, in narration: NSString, from cursor: Int) -> Placement? {
        for (attempt, candidate) in narrationCandidates(page).enumerated() {
            let displayed = normalized(candidate)
            // A trimmed leftover such as a lone page number would match anywhere.
            guard displayed.text.length >= (attempt == 0 ? 1 : 8) else { continue }
            // Literal matching keeps the offset tables aligned with the matched range.
            let match = narration.range(of: displayed.text as String, options: .literal,
                range: NSRange(location: cursor, length: narration.length - cursor))
            if match.location != NSNotFound, match.length == displayed.text.length {
                return Placement(displayOffsets: displayed.offsets,
                                 narration: Array(match.location..<NSMaxRange(match)), end: NSMaxRange(match))
            }
        }
        return nil
    }

    /// PDFKit and Rust extract text separately, so a few lines of a page may differ. The lines that
    /// do match, in reading order and close together, still place the page when they are most of it.
    private static func locateByLines(_ page: String, in narration: NSString, from cursor: Int) -> Placement? {
        var placement = Placement(displayOffsets: [], narration: [], end: cursor)
        var lineStart = 0, total = 0, reach = narration.length
        for line in page.components(separatedBy: "\n") {
            defer { lineStart += line.utf16.count + 1 }
            let displayed = normalized(line)
            let length = displayed.text.length
            total += length
            // A short line is only trusted where the previous one ended.
            let limit = length >= 8 ? min(reach, narration.length) : min(placement.end + length, narration.length)
            guard length > 0, !placement.narration.isEmpty || length >= 8, limit - placement.end >= length else { continue }
            let match = narration.range(of: displayed.text as String, options: .literal,
                range: NSRange(location: placement.end, length: limit - placement.end))
            guard match.location != NSNotFound, match.length == length else { continue }
            if placement.narration.isEmpty { reach = match.location + normalized(page).text.length * 2 }
            placement.displayOffsets += displayed.offsets.map { lineStart + $0 }
            placement.narration += match.location..<NSMaxRange(match)
            placement.end = NSMaxRange(match)
        }
        guard !placement.narration.isEmpty, placement.narration.count * 10 >= total * 7 else { return nil }
        return placement
    }

    /// The page as shown, then without what Rust may leave out of the narration: layout slugs and a
    /// repeated first or last line (running header, page number). Lines are blanked in place, so
    /// UTF-16 offsets still point into the page.
    private static func narrationCandidates(_ page: String) -> [String] {
        let lines = page.components(separatedBy: "\n")
        let filled = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let slugs = Set(filled.filter { lines[$0].lowercased().contains(".indd") || lines[$0].lowercased().contains(".qxd") })
        let content = filled.filter { !slugs.contains($0) }
        guard let first = content.first, let last = content.last else { return [page] }
        return [page] + [[], [last], [first], [first, last]].map { (edges: [Int]) in
            let dropped = slugs.union(edges)
            return lines.indices.map {
                dropped.contains($0) ? String(repeating: " ", count: lines[$0].utf16.count) : lines[$0]
            }.joined(separator: "\n")
        }
    }

    private static func normalized(_ text: String) -> (text: NSString, offsets: [Int], scalarOffsets: [Int]) {
        var result = "", offsets: [Int] = [], scalarOffsets: [Int] = [], offset = 0, scalarOffset = 0
        for scalar in text.unicodeScalars {
            let folded = String(scalar).folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
                                                locale: Locale(identifier: "en_US_POSIX"))
            for value in folded.unicodeScalars where CharacterSet.alphanumerics.contains(value) {
                let fragment = String(value)
                result += fragment
                offsets.append(contentsOf: repeatElement(offset, count: fragment.utf16.count))
                scalarOffsets.append(contentsOf: repeatElement(scalarOffset, count: fragment.utf16.count))
            }
            offset += String(scalar).utf16.count
            scalarOffset += 1
        }
        return (result as NSString, offsets, scalarOffsets)
    }
}

#if canImport(PDFKit)
extension PDFReadingAudioMap {
    /// What each page says: its text layer or, for a page without one, the stored OCR text that Rust
    /// narrates. OCR offsets do not point into the page, so such a page is turned to but not highlighted.
    static func pageTexts(of document: PDFDocument) -> [String] {
        let recognized = document.documentURL.map(PdfOcrPreparer.storedText) ?? [:]
        return (0..<document.pageCount).map { index in
            let text = document.page(at: index)?.string ?? ""
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
            return recognized[index + 1] ?? text
        }
    }

    /// The position in `page.string` of the text touched at `point` (page space).
    /// `characterIndex(at:)` drifts from `page.string` line by line; a word's range does not.
    static func character(at point: CGPoint, on page: PDFPage) -> Int? {
        let index = page.characterIndex(at: point)
        guard index != NSNotFound, index >= 0 else { return nil }
        guard let word = page.selectionForWord(at: point), word.numberOfTextRanges(on: page) > 0 else { return index }
        let start = word.range(at: 0, on: page).location
        return start == NSNotFound ? index : start
    }
}
#endif
