import CoreImage
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import Vision

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

/// Converts scanned two-page spreads into upright, independently navigable PDF pages.
///
/// This is deliberately visual-only: text extraction and TTS retain their own
/// source pipeline. The reader receives a PDFKit document with the same
/// content, but each facing scan is a separate page in normal reading order.
enum PdfReadingPageNormalizer {
    struct RecognizedLine {
        let bounds: CGRect
        let characterCount: Int
        let confidence: Float
    }

    private static let splitBoundary: CGFloat = 0.48
    private static let oppositeSplitBoundary: CGFloat = 0.52
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])
    private static let cacheSchemaVersion = "3"

    /// Returns a replacement document only when the source is a sideways,
    /// scanned two-page spread. Normal PDFs keep their original PDFKit pages.
    static func normalizedDocument(from url: URL) -> PDFDocument? {
        if let cached = cachedDocument(for: url) {
            return cached
        }
        guard let document = PDFDocument(url: url) else { return nil }
        guard let normalized = normalizedDocument(from: document) else { return nil }
        cache(normalized, for: url)
        return normalized
    }

    static func normalizedDocument(from document: PDFDocument) -> PDFDocument? {
        guard document.pageCount > 0,
              hasNoSelectableText(in: document),
              let orientation = spreadOrientation(in: document)
        else {
            return nil
        }
        return separatedDocument(from: document, orientation: orientation)
    }

    /// Splits every physical source page after applying a known sideways scan
    /// orientation. This preserves the source's visual pagination, including
    /// intentionally blank logical pages. Kept internal so deterministic image
    /// geometry has a narrow XCTest seam independent of Vision OCR.
    static func separatedDocument(
        from document: PDFDocument,
        orientation: CGImagePropertyOrientation
    ) -> PDFDocument? {
        guard orientation == .left || orientation == .right else { return nil }
        let result = PDFDocument()
        for index in 0..<document.pageCount {
            guard let sourcePage = document.page(at: index),
                  let rendered = render(sourcePage),
                  let logicalPages = split(rendered, orientation: orientation),
                  logicalPages.count == 2
            else {
                return nil
            }
            for image in logicalPages {
                guard let page = makePDFPage(image: image) else { return nil }
                result.insert(page, at: result.pageCount)
            }
        }
        return result.pageCount == document.pageCount * 2 ? result : nil
    }

    static func isTwoUpSpread(_ lines: [RecognizedLine]) -> Bool {
        let left = lines.filter { $0.bounds.maxX < splitBoundary }
        let right = lines.filter { $0.bounds.minX > oppositeSplitBoundary }
        let middleCount = lines.count - left.count - right.count
        let splitThreshold = max(4, max(left.count, right.count) / 3)
        return left.count >= 6 && right.count >= 6 && middleCount <= splitThreshold
    }

    private static func spreadOrientation(in document: PDFDocument) -> CGImagePropertyOrientation? {
        let positions = [0, document.pageCount / 3, (document.pageCount * 2) / 3, document.pageCount - 1]
        let sampleIndexes = Array(Set(positions)).sorted()
        let orientations: [CGImagePropertyOrientation] = [.right, .left]
        var spreadCounts: [UInt32: Int] = [:]
        var scores: [UInt32: Double] = [:]

        for index in sampleIndexes {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.height > bounds.width, let image = render(page) else { continue }
            for orientation in orientations {
                guard let lines = recognize(image, orientation: orientation) else { continue }
                let rawValue = orientation.rawValue
                scores[rawValue, default: 0] += recognitionScore(lines)
                if isTwoUpSpread(lines) {
                    spreadCounts[rawValue, default: 0] += 1
                }
            }
        }

        return orientations
            .filter { (spreadCounts[$0.rawValue] ?? 0) > 0 }
            .max { left, right in
                (scores[left.rawValue] ?? 0) < (scores[right.rawValue] ?? 0)
            }
    }

    private static func hasNoSelectableText(in document: PDFDocument) -> Bool {
        let positions = [0, document.pageCount / 2, document.pageCount - 1]
        for index in Set(positions) {
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty {
                return false
            }
        }
        return true
    }

    private static func recognize(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> [RecognizedLine]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["pt-PT", "en-US"]
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        } catch {
            return nil
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return RecognizedLine(
                bounds: observation.boundingBox,
                characterCount: candidate.string.count,
                confidence: candidate.confidence
            )
        }
    }

    private static func recognitionScore(_ lines: [RecognizedLine]) -> Double {
        lines.reduce(0) { partial, line in
            partial + Double(line.confidence) * Double(min(line.characterCount, 160))
        }
    }

    private static func split(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> [CGImage]? {
        guard let normalized = normalizedImage(image, orientation: orientation) else {
            return nil
        }
        let extent = normalized.extent.integral
        guard extent.width > extent.height, extent.width >= 2, extent.height > 0 else {
            return nil
        }
        let halfWidth = floor(extent.width / 2)
        let leftRect = CGRect(x: extent.minX, y: extent.minY, width: halfWidth, height: extent.height)
        let rightRect = CGRect(
            x: extent.minX + halfWidth,
            y: extent.minY,
            width: extent.width - halfWidth,
            height: extent.height
        )
        guard let left = imageContext.createCGImage(normalized.cropped(to: leftRect), from: leftRect),
              let right = imageContext.createCGImage(normalized.cropped(to: rightRect), from: rightRect)
        else {
            return nil
        }
        return [left, right]
    }

    private static func normalizedImage(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> CIImage? {
        let oriented = CIImage(cgImage: image)
            .oriented(forExifOrientation: Int32(orientation.rawValue))
        let normalized = oriented.transformed(
            by: CGAffineTransform(
                translationX: -oriented.extent.minX,
                y: -oriented.extent.minY
            )
        )
        return normalized.extent.width > 0 && normalized.extent.height > 0 ? normalized : nil
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            let scaleX = size.width / bounds.width
            let scaleY = size.height / bounds.height
            context.cgContext.scaleBy(x: scaleX, y: scaleY)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }.cgImage
        #else
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            let scaleX = size.width / bounds.width
            let scaleY = size.height / bounds.height
            context.scaleBy(x: scaleX, y: scaleY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    private static func makePDFPage(image: CGImage) -> PDFPage? {
        #if canImport(UIKit)
        PDFPage(image: UIImage(cgImage: image))
        #else
        PDFPage(
            image: NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        )
        #endif
    }

    /// Scanned books can have hundreds of physical pages. Persist the visual
    /// derivative so a warm open loads the already upright logical pages
    /// without repeating Vision sampling and rasterization.
    private static func cachedDocument(for sourceURL: URL) -> PDFDocument? {
        guard let cacheURL = cacheURL(for: sourceURL),
              let document = PDFDocument(url: cacheURL),
              document.pageCount > 0
        else {
            return nil
        }
        return document
    }

    private static func cache(_ document: PDFDocument, for sourceURL: URL) {
        guard let cacheURL = cacheURL(for: sourceURL) else { return }
        let directory = cacheURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let temporaryURL = directory.appendingPathComponent(
                "\(cacheURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp"
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard document.write(to: temporaryURL) else { return }
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    cacheURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: cacheURL)
            }
        } catch {
            // Cache persistence is an optimization. The normalized in-memory
            // document remains valid when a storage provider rejects a write.
        }
    }

    private static func cacheURL(for sourceURL: URL) -> URL? {
        let values = try? sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let sourceIdentity = [
            sourceURL.standardizedFileURL.path,
            cacheSchemaVersion,
            values?.fileSize.map(String.init) ?? "unknown-size",
            values?.contentModificationDate?.timeIntervalSince1970.description ?? "unknown-date",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(sourceIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return caches
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("NormalizedPDF", isDirectory: true)
            .appendingPathComponent("\(digest).pdf", isDirectory: false)
    }
}
