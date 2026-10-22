import Foundation
import PDFKit

extension PdfTextExtractor {
    // MARK: - Chapter assembly

    /// Build chapters using the PDF outline first, then the heading
    /// heuristic, then a single-chapter fallback. Public for unit
    /// testing — callers should prefer `extract(from:bookId:)`.
    static func buildChapters(from document: PDFDocument) -> [EbookFulltext.Chapter] {
        if let outlineChapters = chaptersFromOutline(document: document),
           !outlineChapters.isEmpty {
            return outlineChapters
        }
        let heuristic = chaptersFromHeadingHeuristic(document: document)
        if heuristic.count > 1 {
            return heuristic
        }
        return chaptersFromFallback(document: document)
    }

    // MARK: - Outline-based grouping

    /// Walk the top-level outline and slice the PDF into chapters at
    /// each outline destination's page. Children of an outline node
    /// collapse into the parent's range — we keep the structure flat
    /// because the reader UI doesn't need nested headings to play
    /// audio.
    static func chaptersFromOutline(document: PDFDocument) -> [EbookFulltext.Chapter]? {
        guard let root = document.outlineRoot, root.numberOfChildren > 0 else {
            return nil
        }

        struct Entry { let title: String; let pageIndex: Int }
        var entries: [Entry] = []
        for i in 0..<root.numberOfChildren {
            guard let child = root.child(at: i) else { continue }
            guard let dest = child.destination, let page = dest.page else { continue }
            let pageIndex = document.index(for: page)
            let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(title: label, pageIndex: pageIndex))
        }
        guard !entries.isEmpty else { return nil }

        // Slice page ranges from one entry's page to the next entry's
        // page (exclusive). The final chapter runs to the end of the
        // document.
        var chapters: [EbookFulltext.Chapter] = []
        for (i, entry) in entries.enumerated() {
            let endExclusive = (i + 1 < entries.count)
                ? entries[i + 1].pageIndex
                : document.pageCount
            let text = textForRange(
                document: document,
                from: entry.pageIndex,
                toExclusive: endExclusive
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let name = entry.title.isEmpty ? "Chapter \(chapters.count + 1)" : entry.title
            chapters.append(makeChapter(
                index: chapters.count + 1,
                name: name,
                text: trimmed
            ))
        }
        return chapters.isEmpty ? nil : chapters
    }

    // MARK: - Heading-based grouping

    /// Walk every page, examine its first non-empty line, and start a
    /// new chapter whenever we encounter a line whose font size is at
    /// least 1.4× the running average. This catches the typical
    /// chapter-title style (large bold heading at the top of a page)
    /// without needing a precise outline.
    static func chaptersFromHeadingHeuristic(
        document: PDFDocument,
        sizeThreshold: CGFloat = 1.4
    ) -> [EbookFulltext.Chapter] {
        struct PageHead {
            let pageIndex: Int
            let firstLine: String
            let firstLineFontSize: CGFloat
            let bodyFontSize: CGFloat
        }
        var heads: [PageHead] = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let head = analyzeFirstLine(of: page)
            heads.append(PageHead(
                pageIndex: i,
                firstLine: head.line,
                firstLineFontSize: head.firstSize,
                bodyFontSize: head.bodySize
            ))
        }
        // Average body-font size across the document — used as the
        // baseline a heading must exceed.
        let bodySizes = heads.map { $0.bodyFontSize }.filter { $0 > 0 }
        let avgBody = bodySizes.isEmpty
            ? 0
            : bodySizes.reduce(0, +) / CGFloat(bodySizes.count)

        // Pick chapter break pages: heading larger than threshold * avg,
        // OR first-line text matches a common chapter keyword. The
        // first page is always a chapter start so we don't drop the
        // front matter.
        var breaks: [Int] = []
        for head in heads {
            if head.pageIndex == 0 {
                breaks.append(0)
                continue
            }
            let exceedsSize = avgBody > 0 &&
                head.firstLineFontSize >= avgBody * sizeThreshold
            let keywordHit = looksLikeChapterKeyword(head.firstLine)
            if exceedsSize || keywordHit {
                breaks.append(head.pageIndex)
            }
        }
        if breaks.isEmpty { breaks = [0] }

        var chapters: [EbookFulltext.Chapter] = []
        for (i, breakPage) in breaks.enumerated() {
            let endExclusive = (i + 1 < breaks.count) ? breaks[i + 1] : document.pageCount
            let text = textForRange(
                document: document,
                from: breakPage,
                toExclusive: endExclusive
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let name = heads.first { $0.pageIndex == breakPage }?
                .firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName: String = {
                if let n = name, !n.isEmpty, n.count <= 120 { return n }
                return "Chapter \(chapters.count + 1)"
            }()
            chapters.append(makeChapter(
                index: chapters.count + 1,
                name: resolvedName,
                text: trimmed
            ))
        }
        return chapters
    }

    // MARK: - Fallback

    /// Worst-case fallback: bundle the whole document text into a
    /// single chapter so the reader still has something to render.
    /// Returns an empty array when even this fails (scanned PDFs).
    static func chaptersFromFallback(document: PDFDocument) -> [EbookFulltext.Chapter] {
        let text = textForRange(
            document: document,
            from: 0,
            toExclusive: document.pageCount
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [makeChapter(index: 1, name: "Document", text: text)]
    }

}
