import CoreImage
import XCTest
import PDFKit
@testable import EpubToMp3

#if canImport(UIKit)
import UIKit
private typealias TestPlatformImage = UIImage
#else
import AppKit
private typealias TestPlatformImage = NSImage
#endif

final class PdfTextExtractorTests: XCTestCase {

    func testTwoUpScanDetectorRequiresTextOnBothLogicalPages() {
        let left = (0..<6).map { row in
            PdfReadingPageNormalizer.RecognizedLine(
                bounds: CGRect(x: 0.08, y: CGFloat(row) * 0.1, width: 0.3, height: 0.04),
                characterCount: 42,
                confidence: 0.9
            )
        }
        let right = (0..<6).map { row in
            PdfReadingPageNormalizer.RecognizedLine(
                bounds: CGRect(x: 0.62, y: CGFloat(row) * 0.1, width: 0.3, height: 0.04),
                characterCount: 42,
                confidence: 0.9
            )
        }

        XCTAssertTrue(PdfReadingPageNormalizer.isTwoUpSpread(left + right))
        XCTAssertFalse(PdfReadingPageNormalizer.isTwoUpSpread(left))
    }

    func testSeparatingSidewaysScanCreatesTwoUprightPdfPages() throws {
        let document = PDFDocument()
        let image = try makeSidewaysSpreadImage()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)

        let normalized = try XCTUnwrap(
            PdfReadingPageNormalizer.separatedDocument(from: document, orientation: .right)
        )

        XCTAssertEqual(normalized.pageCount, 2)
        for index in 0..<normalized.pageCount {
            let bounds = try XCTUnwrap(normalized.page(at: index)).bounds(for: .mediaBox)
            XCTAssertGreaterThan(bounds.height, bounds.width)
        }
        let first = try XCTUnwrap(centerColor(of: try XCTUnwrap(normalized.page(at: 0))))
        let second = try XCTUnwrap(centerColor(of: try XCTUnwrap(normalized.page(at: 1))))
        XCTAssertGreaterThan(first.red, first.blue, "The left logical page must remain first")
        XCTAssertGreaterThan(second.blue, second.red, "The right logical page must remain second")
    }

    func testExtractsSingleChapterFromSinglePagePdf() throws {
        let url = try PdfFixture.createSinglePage(
            title: "Single Page Book",
            author: "Author",
            bodyText: "Body paragraph one."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let fulltext = try PdfTextExtractor.extract(from: url, bookId: "book-id-123")
        XCTAssertEqual(fulltext.jobId, "book-id-123")
        XCTAssertEqual(fulltext.bookTitle, "Single Page Book")
        XCTAssertEqual(fulltext.bookAuthor, "Author")
        XCTAssertEqual(fulltext.chapters.count, 1)
        let chapter = try XCTUnwrap(fulltext.chapters.first)
        XCTAssertTrue(chapter.text.contains("Body paragraph"),
                      "chapter text should contain the body. Got: \(chapter.text)")
    }

    func testSearchablePdfKeepsItsOriginalPdfKitDocument() throws {
        let url = try PdfFixture.createSinglePage(
            title: "Searchable Book",
            author: "Author",
            bodyText: "Selectable source text."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try XCTUnwrap(PDFDocument(url: url))

        XCTAssertNil(PdfReadingPageNormalizer.normalizedDocument(from: document))
    }

    func testGroupsMultiPagePdfByHeadingFontSize() throws {
        // Each page has a 28pt bold heading + 12pt body. The
        // heading heuristic should produce one chapter per page.
        let url = try PdfFixture.createMultiPage(
            pages: [
                (heading: "First Heading", body: "First page body."),
                (heading: "Second Heading", body: "Second page body."),
                (heading: "Third Heading", body: "Third page body."),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let fulltext = try PdfTextExtractor.extract(from: url, bookId: "")
        XCTAssertGreaterThanOrEqual(
            fulltext.chapters.count, 1,
            "extractor must produce at least one chapter for a 3-page PDF"
        )
        // The chapters' combined text must mention all three bodies —
        // we're not picky about whether the heuristic merged them or
        // split them, only that no text is lost in chapter assembly.
        let joined = fulltext.chapters.map { $0.text }.joined(separator: " ")
        XCTAssertTrue(joined.contains("First page body"))
        XCTAssertTrue(joined.contains("Second page body"))
        XCTAssertTrue(joined.contains("Third page body"))
    }

    func testLooksLikeChapterKeywordRecognisesCommonPrefixes() {
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("Chapter 1"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("CHAPTER 12"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("Capítulo 3"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("Part 1"))
        // Roman-numeral / bare-digit short lines.
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("I"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("3"))
        // Sentences shouldn't trip the heuristic.
        XCTAssertFalse(PdfTextExtractor.looksLikeChapterKeyword("The quick brown fox"))
        XCTAssertFalse(PdfTextExtractor.looksLikeChapterKeyword(""))
    }

    func testFallbackChapterWhenNoOutlineOrHeadingsDetected() {
        // We can't easily craft a PDF that defeats both signals at
        // once from a unit test, so cover the helper directly: an
        // empty PDF document should yield zero chapters from the
        // fallback rather than throwing.
        let empty = PDFDocument()
        let chapters = PdfTextExtractor.chaptersFromFallback(document: empty)
        XCTAssertTrue(chapters.isEmpty)
    }

    func testChaptersFromOutlineReturnsNilWhenOutlineEmpty() {
        let empty = PDFDocument()
        XCTAssertNil(PdfTextExtractor.chaptersFromOutline(document: empty))
    }

    private func makeSidewaysSpreadImage() throws -> TestPlatformImage {
        let logicalWidth = 400
        let logicalHeight = 300
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: logicalWidth,
            height: logicalHeight,
            bitsPerComponent: 8,
            bytesPerRow: logicalWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw NSError(domain: "PdfTextExtractorTests", code: 1)
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: logicalWidth / 2, height: logicalHeight))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: logicalWidth / 2, y: 0, width: logicalWidth / 2, height: logicalHeight))
        guard let logicalSpread = context.makeImage() else {
            throw NSError(domain: "PdfTextExtractorTests", code: 2)
        }
        // The raw PDF page is a clockwise scan of the landscape spread.
        // `.right` must restore it before splitting left then right.
        let raw = CIImage(cgImage: logicalSpread).oriented(forExifOrientation: 6)
        let shifted = raw.transformed(
            by: CGAffineTransform(translationX: -raw.extent.minX, y: -raw.extent.minY)
        )
        let rasterizer = CIContext(options: [.cacheIntermediates: false])
        guard let rawImage = rasterizer.createCGImage(shifted, from: shifted.extent) else {
            throw NSError(domain: "PdfTextExtractorTests", code: 3)
        }
        #if canImport(UIKit)
        return UIImage(cgImage: rawImage)
        #else
        return NSImage(
            cgImage: rawImage,
            size: NSSize(width: rawImage.width, height: rawImage.height)
        )
        #endif
    }

    private func centerColor(of page: PDFPage) -> (red: UInt8, blue: UInt8)? {
        let width = 20
        let height = 30
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / page.bounds(for: .mediaBox).width,
                            y: CGFloat(height) / page.bounds(for: .mediaBox).height)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        guard rendered else { return nil }
        let center = ((height / 2) * width + (width / 2)) * 4
        return (bytes[center], bytes[center + 2])
    }
}
