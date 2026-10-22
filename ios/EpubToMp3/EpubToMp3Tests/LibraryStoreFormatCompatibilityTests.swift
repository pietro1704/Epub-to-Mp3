import XCTest

@testable import EpubToMp3

extension LibraryStoreTests {
    func testImportPdfStoresFileTypeAndMetadata() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let pdf = try PdfFixture.createSinglePage(
            title: "Imported PDF",
            author: "PDF Author",
            bodyText: "Body text."
        )
        defer { try? FileManager.default.removeItem(at: pdf) }

        let book = try store.importBook(from: pdf)
        XCTAssertEqual(book.fileType, .pdf)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(book.title, "Imported PDF")
        XCTAssertEqual(book.author, "PDF Author")
        // PDFKit should have produced a cover thumbnail.
        XCTAssertNotNil(book.coverPNG)
    }

    func testImportRejectsUnsupportedExtensionInsteadOfSilentlyTreatingAsEpub() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-book-\(UUID().uuidString).txt")
        try Data("plain text file".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try store.importBook(from: tmp)) { error in
            XCTAssertTrue((error as NSError).localizedDescription.contains(tmp.lastPathComponent))
        }
        XCTAssertTrue(store.books.isEmpty)
    }

    func testImportAcceptsFb2AndCbzExtensions() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fb2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-\(UUID().uuidString).fb2")
        try Data("<FictionBook/>".utf8).write(to: fb2)
        let cbz = FileManager.default.temporaryDirectory
            .appendingPathComponent("comic-\(UUID().uuidString).cbz")
        try Data("pk-not-really-a-zip".utf8).write(to: cbz)
        defer {
            try? FileManager.default.removeItem(at: fb2)
            try? FileManager.default.removeItem(at: cbz)
        }

        let fb2Book = try store.importBook(from: fb2)
        let cbzBook = try store.importBook(from: cbz)
        XCTAssertEqual(fb2Book.fileType, .fb2)
        XCTAssertEqual(cbzBook.fileType, .cbz)
        XCTAssertEqual(store.books.count, 2)
    }

    func testLibraryAcceptsBothEpubAndPdfInSameSession() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let epub = try EpubFixture.create()
        let pdf = try PdfFixture.createSinglePage()
        defer {
            try? FileManager.default.removeItem(at: epub)
            try? FileManager.default.removeItem(at: pdf)
        }

        let epubBook = try store.importBook(from: epub)
        let pdfBook = try store.importBook(from: pdf)
        XCTAssertEqual(epubBook.fileType, .epub)
        XCTAssertEqual(pdfBook.fileType, .pdf)
        XCTAssertEqual(store.books.count, 2)
    }

    func testBookEntityDecodingFallsBackToEpubForLegacyPersistedRow() throws {
        // Simulate a row persisted by a pre-PDF-support build: every
        // current field is there, but `fileType` is missing. The
        // decoder should default to `.epub` so the library doesn't
        // crash on first launch after the upgrade.
        let legacyJSON = """
        {
            "id": "legacy-id",
            "title": "Legacy Book",
            "bookmark": "",
            "displayFilename": "legacy.epub",
            "addedAt": 0,
            "cachedOffline": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BookEntity.self, from: legacyJSON)
        XCTAssertEqual(decoded.fileType, .epub)
    }

    func testBookEntityDecodingDetectsPdfFromLegacyFilenameWhenFileTypeMissing() throws {
        let legacyJSON = """
        {
            "id": "legacy-pdf-id",
            "title": "Legacy PDF",
            "bookmark": "",
            "displayFilename": "legacy.pdf",
            "addedAt": 0,
            "cachedOffline": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BookEntity.self, from: legacyJSON)
        XCTAssertEqual(decoded.fileType, .pdf,
                       "legacy entries with a .pdf displayFilename should infer fileType=.pdf")
    }
}
