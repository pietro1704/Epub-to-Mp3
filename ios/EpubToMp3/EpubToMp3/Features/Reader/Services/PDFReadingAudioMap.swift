import Foundation

/// Maps PDFKit character positions to the exact Rust narration chapter axis.
/// Matching is ordered across physical pages, so repeated paragraphs cannot
/// resolve to an earlier occurrence. Unmapped/scanned pages fail closed.
struct PDFReadingAudioMap: Sendable {
    struct Chapter: Decodable, Sendable {
        let index: String
        let name: String
        let sourcePath: String
        let text: String
        var startPage: Int? { Int(sourcePath.replacingOccurrences(of: "page-", with: "")).map { $0 - 1 } }
    }
    struct Metadata: Decodable { let chapters: [Chapter] }
    struct Anchor: Equatable { let chapterIndex: Int; let ratio: Double }
    struct Page: Sendable {
        let chapterIndex: Int
        let displayOffsets: [Int]
        let chapterOffsets: [Int]
        let speechOffsets: [Int]
        let chapterLength: Int
    }
    let chapters: [Chapter]
    let pages: [Int: Page]

    init(metadata: Data, pageTexts: [String]) throws {
        chapters = try JSONDecoder().decode(Metadata.self, from: metadata).chapters
        var mapped: [Int: Page] = [:]
        for (chapterIndex, chapter) in chapters.enumerated() {
            guard let start = chapter.startPage, pageTexts.indices.contains(start) else { continue }
            let end = min(chapters.dropFirst(chapterIndex + 1).first?.startPage ?? pageTexts.count, pageTexts.count)
            guard end > start else { continue }
            let canonical = Self.normalized(chapter.text)
            var cursor = 0
            for pageIndex in start..<end {
                let displayed = Self.normalized(pageTexts[pageIndex])
                guard displayed.text.length > 0, cursor <= canonical.text.length else { continue }
                let match = canonical.text.range(of: displayed.text as String,
                    range: NSRange(location: cursor, length: canonical.text.length - cursor))
                guard match.location != NSNotFound else { continue }
                mapped[pageIndex] = Page(chapterIndex: chapterIndex, displayOffsets: displayed.offsets,
                    chapterOffsets: Array(canonical.offsets[match.location..<NSMaxRange(match)]),
                    speechOffsets: Array(canonical.scalarOffsets[match.location..<NSMaxRange(match)]),
                    chapterLength: chapter.text.unicodeScalars.count)
                cursor = NSMaxRange(match)
            }
        }
        pages = mapped
    }

    func anchor(page: Int, character: Int = 0) -> Anchor? {
        guard let mapped = pages[page], mapped.chapterLength > 0,
              !mapped.displayOffsets.isEmpty else { return nil }
        let index = mapped.displayOffsets.firstIndex(where: { $0 >= max(0, character) }) ?? mapped.displayOffsets.count - 1
        return Anchor(chapterIndex: mapped.chapterIndex,
                      ratio: Double(mapped.speechOffsets[index]) / Double(mapped.chapterLength))
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
