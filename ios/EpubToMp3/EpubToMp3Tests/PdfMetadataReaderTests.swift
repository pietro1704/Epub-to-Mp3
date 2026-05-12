import XCTest
import PDFKit
@testable import EpubToMp3

final class PdfMetadataReaderTests: XCTestCase {

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

    func testProducesCoverPNGForFirstPage() throws {
        let url = try PdfFixture.createSinglePage(
            title: "Cover Test",
            author: "Author",
            bodyText: "Body"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try PdfMetadataReader.readMetadata(from: url)
        // The cover should at minimum decode as a valid image. We
        // don't pin exact bytes — the platform renderer is free to
        // emit slightly different PNGs across iOS releases.
        let cover = try XCTUnwrap(payload.cover)
        XCTAssertGreaterThan(cover.count, 100, "cover PNG looks too small to be a real render")
        // PNG magic header — first 4 bytes are always \x89 P N G.
        XCTAssertEqual([UInt8](cover.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
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
