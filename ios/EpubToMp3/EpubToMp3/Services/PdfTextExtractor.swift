import Foundation
import PDFKit

/// Extracts plain text from a PDF and groups it into pseudo-chapters
/// so the reader / TTS pipeline can consume it through the same
/// `EbookFulltext` model used for EPUB.
///
/// Strategy (in priority order):
///   1. PDF outline (`document.outlineRoot`) — if the author shipped
///      a TOC, use it verbatim. Each top-level outline entry becomes
///      a chapter; child entries collapse into the parent's text.
///   2. Heading heuristic — pages where the first non-empty line is
///      noticeably larger than the body (≥1.4× average font size) are
///      treated as chapter starts.
///   3. Fall back to a single "Document" chapter when neither signal
///      is available (e.g. scanned PDFs that PDFKit cannot OCR).
enum PdfTextExtractor {

    /// Errors surfaced when the document can't be turned into text.
    enum ExtractError: Error, LocalizedError {
        case openFailed(String)
        case encrypted(String)
        case noTextRecovered(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let name):
                return "PDFKit could not open \(name)."
            case .encrypted(let name):
                return "\(name) is password-protected."
            case .noTextRecovered(let name):
                return "\(name) appears to be a scanned image PDF — no selectable text. OCR is not supported in-app yet."
            }
        }
    }

    /// Extract pseudo-chapters from `url` and wrap them in the same
    /// `EbookFulltext` shape the EPUB pipeline emits. `bookId` becomes
    /// the surface `jobId` (mirrors `parse_epub_to_dict` behaviour).
    static func extract(from url: URL, bookId: String) throws -> EbookFulltext {
        guard let document = PDFDocument(url: url) else {
            throw ExtractError.openFailed(url.lastPathComponent)
        }
        if document.isEncrypted && !document.unlock(withPassword: "") {
            throw ExtractError.encrypted(url.lastPathComponent)
        }

        let bookTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            ?? deriveTitleFromFilename(url)
        let bookAuthor = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String

        let chapters = buildChapters(from: document)
        guard !chapters.isEmpty else {
            throw ExtractError.noTextRecovered(url.lastPathComponent)
        }

        return EbookFulltext(
            jobId: bookId,
            bookTitle: bookTitle,
            bookAuthor: bookAuthor,
            chapters: chapters
        )
    }

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

    // MARK: - Utilities

    /// Glues together page strings in `[from, toExclusive)`. Adds a
    /// blank line between pages so paragraphs don't run together.
    static func textForRange(
        document: PDFDocument,
        from: Int,
        toExclusive: Int
    ) -> String {
        var pieces: [String] = []
        for i in from..<min(toExclusive, document.pageCount) {
            guard let page = document.page(at: i), let s = page.string else { continue }
            pieces.append(s)
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Inspect a page's first non-empty line and report its font size
    /// plus the average font size of the rest of the page (the body).
    /// We use `PDFPage.attributedString` so we have run-by-run font
    /// metadata; falling back to plain `string` when attributedString
    /// isn't available.
    static func analyzeFirstLine(of page: PDFPage) -> (line: String, firstSize: CGFloat, bodySize: CGFloat) {
        guard let attributed = page.attributedString, attributed.length > 0 else {
            let plain = page.string ?? ""
            let firstLine = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return (firstLine.trimmingCharacters(in: .whitespacesAndNewlines), 0, 0)
        }

        let full = attributed.string
        let nsFull = full as NSString
        var firstLine = ""
        var firstLineRange = NSRange(location: 0, length: 0)

        // Walk newlines to find the first non-blank line.
        var cursor = 0
        while cursor < nsFull.length {
            let nlRange = nsFull.range(
                of: "\n",
                options: [],
                range: NSRange(location: cursor, length: nsFull.length - cursor)
            )
            let endExclusive = (nlRange.location == NSNotFound)
                ? nsFull.length
                : nlRange.location
            let lineRange = NSRange(location: cursor, length: endExclusive - cursor)
            let lineRaw = nsFull.substring(with: lineRange)
            let trimmed = lineRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                firstLine = trimmed
                firstLineRange = lineRange
                break
            }
            cursor = (nlRange.location == NSNotFound) ? nsFull.length : nlRange.location + 1
        }

        if firstLine.isEmpty {
            return ("", 0, 0)
        }

        // Font size of the first line: take the dominant size in the
        // attributed-string range we identified.
        var firstSize: CGFloat = 0
        attributed.enumerateAttribute(
            .font,
            in: firstLineRange,
            options: []
        ) { value, _, _ in
            if let font = value as? PlatformFont, font.pointSize > firstSize {
                firstSize = font.pointSize
            }
        }
        // Body size: average across the rest of the page.
        var bodySizesSum: CGFloat = 0
        var bodySizesCount: Int = 0
        let restStart = firstLineRange.location + firstLineRange.length
        if restStart < nsFull.length {
            attributed.enumerateAttribute(
                .font,
                in: NSRange(location: restStart, length: nsFull.length - restStart),
                options: []
            ) { value, range, _ in
                if let font = value as? PlatformFont, font.pointSize > 0 {
                    bodySizesSum += font.pointSize * CGFloat(range.length)
                    bodySizesCount += range.length
                }
            }
        }
        let bodySize: CGFloat = bodySizesCount > 0
            ? bodySizesSum / CGFloat(bodySizesCount)
            : 0
        return (firstLine, firstSize, bodySize)
    }

    /// Heuristic: does this line look like a chapter title? We accept
    /// pt-BR ("Capítulo …"), en-US ("Chapter …"), and bare numerals.
    /// Caller already filtered to "first non-empty line of a page".
    static func looksLikeChapterKeyword(_ line: String) -> Bool {
        let lower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["chapter ", "capítulo ", "capitulo ", "part ", "parte "]
        for p in prefixes where lower.hasPrefix(p) { return true }
        // A short numeric-only line ("1", "01", "II"): assume heading.
        if lower.count <= 4, !lower.isEmpty,
           lower.allSatisfy({ $0.isNumber || $0 == "i" || $0 == "v" || $0 == "x" }) {
            return true
        }
        return false
    }

    private static func makeChapter(
        index: Int,
        name: String,
        text: String
    ) -> EbookFulltext.Chapter {
        EbookFulltext.Chapter(
            index: index,
            name: name,
            text: text,
            html: nil,
            css: nil,
            charCount: text.count,
            segments: nil
        )
    }

    private static func deriveTitleFromFilename(_ url: URL) -> String {
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        return base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

// MARK: - Platform font alias
//
// `PlatformFont` is defined module-wide in `EpubHtmlRenderer.swift`.
// Keep the import here so this file compiles standalone but don't
// re-declare the typealias — Swift fails the build with
// "invalid redeclaration" because both files end up in the same
// module.
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
