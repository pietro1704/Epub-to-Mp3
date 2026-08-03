import XCTest
@testable import EpubToMp3

final class LibraryStoreTests: XCTestCase {

    private func ephemeralStore() -> (LibraryStore, UserDefaults, String) {
        let suite = "library.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        return (store, defaults, suite)
    }

    func testStoreStartsEmpty() {
        let (store, _, suite) = ephemeralStore()
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(store.loadError)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testLoadMigratesPersistedLocalizationKeyOutOfAuthor() throws {
        let suite = "library.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = BookEntity(
            id: "bad-author",
            title: "Book",
            author: "reader.loading",
            bookmark: Data([1]),
            displayFilename: "book.epub",
            addedAt: .now
        )
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.books.v1")

        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        XCTAssertNil(store.books.first?.author)
    }

    func testUITestFixtureInstallsDeterministicBook() {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.installUITestFixtureIfRequested(arguments: ["-uiTestFixture"])

        XCTAssertEqual(store.books.map(\.id), ["ui-test-book"])
        XCTAssertEqual(store.books.first?.title, "UI Test Book")
    }

    func testDevelopmentSeedBookImportsOnlyWhenRequestedAndDeduplicates() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: seed) }

        XCTAssertFalse(store.installDevelopmentSeedBookIfRequested(seedURL: seed))
        XCTAssertTrue(
            store.installDevelopmentSeedBookIfRequested(
                arguments: ["-developmentSeedBook"],
                seedURL: seed
            )
        )
        XCTAssertEqual(store.books.map(\.title), [EpubFixture.title])
        XCTAssertTrue(
            store.installDevelopmentSeedBookIfRequested(
                arguments: ["-developmentSeedBook"],
                seedURL: seed
            )
        )
        XCTAssertEqual(store.books.count, 1)
    }

    func testContentHashIsStableAcrossInvocations() throws {
        // Write a deterministic file and ensure the SHA-256-based id is
        // identical across invocations — required for the de-dup path.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-test-\(UUID().uuidString).epub")
        let payload = Data(repeating: 0x42, count: 8 * 1024)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let h1 = try LibraryStore.contentHash(of: tmp)
        let h2 = try LibraryStore.contentHash(of: tmp)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 32)
        XCTAssertEqual(h1, h1.lowercased())
    }

    func testContentHashChangesWhenFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("a-\(UUID().uuidString).epub")
        let b = dir.appendingPathComponent("b-\(UUID().uuidString).epub")
        try Data(repeating: 0x01, count: 1024).write(to: a)
        try Data(repeating: 0x02, count: 1024).write(to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertNotEqual(try LibraryStore.contentHash(of: a),
                          try LibraryStore.contentHash(of: b))
    }

    func testImportThenRemoveRoundtrip() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Build a tiny EPUB-shaped file so importBook has something
        // hashable. We don't need a valid container.xml — the
        // metadata reader gracefully returns an empty payload.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-test-\(UUID().uuidString).epub")
        try Data("not-a-real-epub-but-hashable".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let book = try store.importBook(from: tmp)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books.first?.id, book.id)

        store.remove(id: book.id)
        XCTAssertTrue(store.books.isEmpty)
    }

    @MainActor
    func testAsyncOpenResolvesAnImportedBook() async throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-async-open-\(UUID().uuidString).epub")
        try Data("async-open-fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let book = try store.importBook(from: file)
        let resolved = try await store.openBookFileAsync(id: book.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        XCTAssertNotNil(store.books.first?.lastOpenedAt)
    }

    func testImportSameFileTwiceDeduplicates() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-dedup-\(UUID().uuidString).epub")
        try Data("dedup-fixture".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.importBook(from: tmp)
        _ = try store.importBook(from: tmp)
        XCTAssertEqual(store.books.count, 1,
                       "importing the same file twice must collapse to a single entry")
    }

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

    func testDurableImportCopySurvivesOriginalRemoval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-durable-root-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-picked-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("Picked Book.epub")
        try Data("durable import payload".utf8).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        let durable = try LibraryStore.persistImportedFileForLibrary(
            originalURL: source,
            id: "abc123",
            fileType: .epub,
            baseDirectory: root
        )
        try FileManager.default.removeItem(at: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.path))
        XCTAssertEqual(try Data(contentsOf: durable), Data("durable import payload".utf8))
        XCTAssertTrue(durable.path.hasPrefix(root.path))
        XCTAssertEqual(durable.lastPathComponent, "Picked Book.epub")
    }

    #if os(macOS)
    func testMacOSImportUsesAnAppOwnedCopyForFutureAccess() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-library-import-\(UUID().uuidString).epub")
        let payload = Data("macOS durable library payload".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let book = try store.importBook(from: source)
        let resolved = try store.openBookFile(id: book.id).standardizedFileURL
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
            .path

        XCTAssertTrue(
            resolved.path.hasPrefix(applicationSupport + "/EpubToMp3/ImportedBooks/"),
            "macOS library access must resolve to an app-owned copy instead of the picked Documents/external URL"
        )
        XCTAssertNotEqual(resolved, source.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: resolved), payload)
    }
    #endif
}
