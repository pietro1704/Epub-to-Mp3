import Foundation
import PDFKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
                return "\(name) appears to be a scanned image PDF — no selectable text is available locally."
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

    static func makeChapter(
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
