import XCTest
@testable import EpubToMp3

/// PDF-OCR-IMAGE-PAGES, Apple part: Vision reads image-only pages and Rust narrates them.
final class PdfOcrPreparerTests: XCTestCase {
    func testStoredBlankAndFailingPagesDoNotStopTheOthers() async throws {
        let directory = try temporaryDirectory()
        let book = directory.appendingPathComponent("book.pdf")
        try Data(#"{"pages":{"1":"already read"}}"#.utf8)
            .write(to: URL(fileURLWithPath: book.path + ".ocr.json"))
        let stored = Recorder()
        let preparer = PdfOcrPreparer(
            listPages: { _ in [1, 2, 3, 4] },
            recognize: { _, page in
                if page == 2 { throw CocoaError(.fileReadUnknown) }
                return page == 3 ? "   " : " page \(page) "
            },
            store: { _, page, text in stored.add("\(page):\(text)") })

        let read = try await preparer.prepare(book)

        XCTAssertEqual(read, 1)
        XCTAssertEqual(stored.values, ["4:page 4"])
    }

    func testCancelledListeningStopsBeforeTheNextPage() async throws {
        let preparer = PdfOcrPreparer(
            listPages: { _ in [1] },
            recognize: { _, _ in XCTFail("No page is read after cancellation"); return "" },
            store: { _, _, _ in })
        let book = try temporaryDirectory().appendingPathComponent("book.pdf")

        do {
            _ = try await preparer.prepare(book) { true }
            XCTFail("A cancelled preparation must not report success")
        } catch is CancellationError {}
    }

    func testOtherFormatsAreNotRead() async throws {
        let preparer = PdfOcrPreparer(
            listPages: { _ in XCTFail("An EPUB has no image pages to list"); return [] },
            recognize: { _, _ in "" }, store: { _, _, _ in })

        let read = try await preparer.prepare(URL(fileURLWithPath: "/fixture-only/book.epub"))

        XCTAssertEqual(read, 0)
    }

    func testVisionTextOfAnImagePageReachesTheRustNarration() async throws {
        let source = try temporaryDirectory().appendingPathComponent("mixed.pdf")
        try ScannedPdfFixture.write([
            .text("The first page of this book already has text that can be selected and narrated."),
            .image("The lighthouse keeper counted seven grey boats before breakfast."),
        ], to: source)
        let adapter = ConverterFFIAdapter()
        XCTAssertEqual(try adapter.pdfImagePages(at: source), [2])

        let read = try await PdfOcrPreparer.vision(adapter: adapter).prepare(source)

        XCTAssertEqual(read, 1)
        let metadata = String(decoding: try adapter.openBook(at: source).metadataJSON, as: UTF8.self)
        XCTAssertTrue(metadata.contains("lighthouse keeper"), metadata)
        let again = try await PdfOcrPreparer.vision(adapter: adapter).prepare(source)
        XCTAssertEqual(again, 0)
    }

    func testRecognitionLanguagesPreferTheBookThenPortuguese() {
        let supported = ["en-US", "fr-FR", "pt-BR", "es-ES"]
        XCTAssertEqual(VisionPageReader.recognitionLanguages(bookLanguage: "es", supported: supported),
                       ["es-ES", "pt-BR", "en-US"])
        XCTAssertEqual(VisionPageReader.recognitionLanguages(bookLanguage: nil, supported: supported),
                       ["pt-BR", "en-US"])
        XCTAssertEqual(VisionPageReader.recognitionLanguages(bookLanguage: "pt-BR", supported: ["en-US"]),
                       ["en-US"])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PdfOcr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
