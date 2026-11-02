import XCTest
import PDFKit
#if canImport(AppKit) && !canImport(UIKit)
import AppKit
#endif
@testable import EpubToMp3

final class PdfMetadataReaderTests: XCTestCase {

    #if canImport(AppKit) && !canImport(UIKit)
    func testCoverOrientationMatchesPDFKitThumbnail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-cover-orientation-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        // PDF coordinates place the red half above the blue half. Use a real
        // PDF context rather than the production thumbnail drawing path.
        let source = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: source as CFMutableData))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(bounds)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 150, width: 200, height: 150))
        context.endPDFPage()
        context.closePDF()
        try (source as Data).write(to: url)
        let original = try Data(contentsOf: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let reference = page.thumbnail(of: bounds.size, for: .mediaBox)
        let referenceBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(reference.tiffRepresentation)))
        let cover = try XCTUnwrap(PdfMetadataReader.readMetadata(from: url).cover)
        let actualBitmap = try XCTUnwrap(NSBitmapImageRep(data: cover))
        XCTAssertEqual(try Data(contentsOf: url), original)

        for fraction in [0.25, 0.75] {
            let expected = try XCTUnwrap(referenceBitmap.colorAt(
                x: referenceBitmap.pixelsWide / 2,
                y: Int(Double(referenceBitmap.pixelsHigh) * fraction)
            )?.usingColorSpace(.deviceRGB))
            let actual = try XCTUnwrap(actualBitmap.colorAt(
                x: actualBitmap.pixelsWide / 2,
                y: Int(Double(actualBitmap.pixelsHigh) * fraction)
            )?.usingColorSpace(.deviceRGB))
            // JPEG and PDFKit may use different color profiles. Orientation
            // depends on which color occupies each half, not exact RGB values.
            XCTAssertGreaterThan(abs(expected.redComponent - expected.blueComponent), 0.6)
            XCTAssertGreaterThan(abs(actual.redComponent - actual.blueComponent), 0.6)
            XCTAssertEqual(actual.redComponent > actual.blueComponent,
                           expected.redComponent > expected.blueComponent)
        }
        let attachment = XCTAttachment(data: cover, uniformTypeIdentifier: "public.jpeg")
        attachment.name = "pdf-cover-orientation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    func testReadsTitleAndAuthorFromDocumentAttributes() throws {
        let url = try PdfFixture.createSinglePage(
            title: "My PDF Book",
            author: "Jane Doe",
            bodyText: "Body text body text body text."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try PdfMetadataReader.readMetadata(from: url)
        XCTAssertEqual(payload.title, "My PDF Book")
        XCTAssertEqual(payload.author, "Jane Doe")
        XCTAssertEqual(payload.pageCount, 1)
    }

    func testProducesCoverJPEGForFirstPage() throws {
        let url = try PdfFixture.createSinglePage(
            title: "Cover Test",
            author: "Author",
            bodyText: "Body"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try PdfMetadataReader.readMetadata(from: url)
        // The cover should at minimum decode as a valid image. We
        // don't pin exact bytes — the platform renderer is free to
        // emit slightly different JPEGs across iOS releases.
        let cover = try XCTUnwrap(payload.cover)
        XCTAssertGreaterThan(cover.count, 100, "cover JPEG looks too small to be a real render")
        // JPEG magic header — first 2 bytes are always \xFF \xD8.
        XCTAssertEqual([UInt8](cover.prefix(2)), [0xFF, 0xD8])
    }

    func testMultiPagePageCount() throws {
        let url = try PdfFixture.createMultiPage(
            pages: [
                (heading: "One", body: "First page body."),
                (heading: "Two", body: "Second page body."),
                (heading: "Three", body: "Third page body."),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = try PdfMetadataReader.readMetadata(from: url)
        XCTAssertEqual(payload.pageCount, 3)
    }

    func testThrowsOpenFailedForMalformedFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-pdf-\(UUID().uuidString).pdf")
        try? Data("not a real PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try PdfMetadataReader.readMetadata(from: url)) { error in
            guard let err = error as? PdfMetadataReader.ReaderError else {
                XCTFail("expected ReaderError, got \(error)")
                return
            }
            switch err {
            case .openFailed: break
            default: XCTFail("expected .openFailed, got \(err)")
            }
        }
    }
}
