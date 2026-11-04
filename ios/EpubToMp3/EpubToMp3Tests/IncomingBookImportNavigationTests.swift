import XCTest
@testable import EpubToMp3

@MainActor
final class IncomingBookImportNavigationTests: XCTestCase {
    func testUnchangedSelectionOpensDurableEPUBImport() async throws {
        try await verifySuccessfulImport(format: .epub, initialSelection: "initial-reader")
    }

    func testEmptySelectionOpensDurablePDFImport() async throws {
        try await verifySuccessfulImport(format: .pdf, initialSelection: nil)
    }

    func testBookSelectedDuringCopyKeepsSelectionAndImportedBook() async throws {
        try await verifySelectionDuringCopy(replacement: "newer-reader")
    }

    func testReaderDismissedDuringCopyStaysDismissedAndKeepsImportedBook() async throws {
        try await verifySelectionDuringCopy(replacement: nil)
    }

    func testSelectionBeforeTaskStartsCannotBeOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        ReaderSessionState.setCurrentlyReading(bookID: "newer-reader", defaults: fixture.defaults)

        await task.value

        XCTAssertEqual(fixture.selection, "newer-reader")
        try fixture.assertDurableImport(from: source)
    }

    func testNewerIncomingFileWinsWhileBothImportsAreRetained() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let older = try fixture.makeSource(body: "Older incoming book.")
        let newer = try fixture.makeSource(body: "Newer incoming book.")
        let copying = expectation(description: "Older incoming copy is suspended")
        fixture.files.pauseNextCopy(until: copying)
        defer { fixture.files.releaseCopy() }
        let olderTask = try XCTUnwrap(fixture.app.handleIncomingURL(older))
        await fulfillment(of: [copying], timeout: 3)

        let newerTask = try XCTUnwrap(fixture.app.handleIncomingURL(newer))
        fixture.files.releaseCopy()
        await olderTask.value
        await newerTask.value

        let imported = try XCTUnwrap(fixture.library.books.first { $0.displayFilename == newer.lastPathComponent })
        XCTAssertEqual(fixture.selection, imported.id)
        XCTAssertEqual(fixture.library.books.count, 2)
        try fixture.assertDurableImport(from: older)
        try fixture.assertDurableImport(from: newer)
    }

    func testFailedNewerRequestDoesNotReviveOlderNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let copying = expectation(description: "Older incoming copy is suspended")
        fixture.files.pauseNextCopy(until: copying)
        defer { fixture.files.releaseCopy() }
        let olderTask = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        await fulfillment(of: [copying], timeout: 3)

        let missing = fixture.root.appendingPathComponent("missing.epub")
        let newerTask = try XCTUnwrap(fixture.app.handleIncomingURL(missing))
        fixture.files.releaseCopy()
        await olderTask.value
        await newerTask.value

        XCTAssertEqual(fixture.selection, "initial-reader")
        XCTAssertEqual(fixture.library.books.count, 1)
        try fixture.assertDurableImport(from: source)
    }

    func testSameBookDeepLinkSupersedesIncomingImport() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let existingSource = try fixture.makeSource(body: "Existing reader book.")
        let existing = try await fixture.library.importBookAsync(from: existingSource)
        ReaderSessionState.setCurrentlyReading(bookID: existing.id, defaults: fixture.defaults)
        let source = try fixture.makeSource()
        let copying = expectation(description: "Incoming copy is suspended")
        fixture.files.pauseNextCopy(until: copying)
        defer { fixture.files.releaseCopy() }
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        await fulfillment(of: [copying], timeout: 3)

        let deepLink = try XCTUnwrap(URL(string: "epubtomp3://book?bookId=\(existing.id)"))
        XCTAssertNil(fixture.app.handleIncomingURL(deepLink))
        fixture.files.releaseCopy()
        await task.value

        XCTAssertEqual(fixture.selection, existing.id)
        try fixture.assertDurableImport(from: source)
    }

    func testUnknownBookDeepLinkDoesNotDiscardValidImportNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        let deepLink = try XCTUnwrap(URL(string: "epubtomp3://book?bookId=unknown-book"))
        XCTAssertNil(fixture.app.handleIncomingURL(deepLink))

        await task.value

        XCTAssertEqual(fixture.selection, fixture.library.books.first?.id)
        try fixture.assertDurableImport(from: source)
    }

    func testCopyFailureKeepsSelectionSourceAndEmptyCatalog() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let original = try Data(contentsOf: source)
        fixture.files.failNextCopy()
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))

        await task.value

        XCTAssertEqual(fixture.selection, "initial-reader")
        XCTAssertTrue(fixture.library.books.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(fixture.reloadedLibrary().books.isEmpty)
    }

    func testCancellationDuringCopyCannotSelectOrPublishBook() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let original = try Data(contentsOf: source)
        let copying = expectation(description: "Incoming copy is suspended")
        fixture.files.pauseNextCopy(until: copying)
        defer { fixture.files.releaseCopy() }
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        await fulfillment(of: [copying], timeout: 3)

        task.cancel()
        fixture.files.releaseCopy()
        await task.value

        XCTAssertEqual(fixture.selection, "initial-reader")
        XCTAssertTrue(fixture.library.books.isEmpty)
        XCTAssertTrue(fixture.reloadedLibrary().books.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCancellationBeforeTaskStartsDoesNotImportOrNavigate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        task.cancel()

        await task.value

        XCTAssertEqual(fixture.selection, "initial-reader")
        XCTAssertTrue(fixture.library.books.isEmpty)
        XCTAssertTrue(fixture.files.copyThreads.isEmpty)
    }

    func testCancellationDuringPersistenceKeepsImportWithoutNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let encoding = expectation(description: "Published import is waiting for persistence")
        fixture.encoder.pauseNextEncoding(until: encoding)
        defer { fixture.encoder.releaseEncoding() }
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        await fulfillment(of: [encoding], timeout: 3)

        XCTAssertEqual(fixture.library.books.count, 1)
        task.cancel()
        fixture.encoder.releaseEncoding()
        await task.value

        XCTAssertEqual(fixture.selection, "initial-reader")
        try fixture.assertDurableImport(from: source)
    }

    func testBookRemovedDuringPersistenceCannotBecomeReaderSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let encoding = expectation(description: "Published import is waiting for persistence")
        fixture.encoder.pauseNextEncoding(until: encoding)
        defer { fixture.encoder.releaseEncoding() }
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        await fulfillment(of: [encoding], timeout: 3)

        let imported = try XCTUnwrap(fixture.library.books.first)
        fixture.library.remove(id: imported.id)
        fixture.encoder.releaseEncoding()
        await task.value
        try await fixture.library.flushPersistence()

        XCTAssertEqual(fixture.selection, "initial-reader")
        XCTAssertTrue(fixture.library.books.isEmpty)
        XCTAssertTrue(fixture.reloadedLibrary().books.isEmpty)
    }

    private func verifySuccessfulImport(format: BookFileType, initialSelection: String?) async throws {
        let fixture = try Fixture(initialSelection: initialSelection)
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource(format: format)
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))

        await task.value

        let imported = try XCTUnwrap(fixture.library.books.first)
        XCTAssertEqual(fixture.selection, imported.id)
        XCTAssertEqual(imported.fileType, format)
        try fixture.assertDurableImport(from: source)
    }

    private func verifySelectionDuringCopy(replacement: String?) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let copying = expectation(description: "Incoming copy is suspended")
        fixture.files.pauseNextCopy(until: copying)
        defer { fixture.files.releaseCopy() }
        let task = try XCTUnwrap(fixture.app.handleIncomingURL(source))
        await fulfillment(of: [copying], timeout: 3)

        ReaderSessionState.setCurrentlyReading(bookID: replacement, defaults: fixture.defaults)
        fixture.files.releaseCopy()
        await task.value

        XCTAssertEqual(fixture.selection, replacement)
        XCTAssertEqual(fixture.files.copyThreads, [false])
        try fixture.assertDurableImport(from: source)
    }

    @MainActor
    private final class Fixture {
        let suite = "incoming-book-import-\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let files = ObservedImportFileManager()
        let encoder = LibraryEncoderProbe()
        let library: LibraryStore
        let app: EpubToMp3App
        private var sourceContents: [URL: Data] = [:]

        var selection: String? { defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) }

        init(initialSelection: String? = "initial-reader") throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let probe = encoder
            library = LibraryStore(defaults: defaults, fileManager: files,
                                   importDirectory: root.appendingPathComponent("library"),
                                   indexEncoder: { try probe.encode($0) })
            app = EpubToMp3App(library: library, sessionDefaults: defaults)
            ReaderSessionState.setCurrentlyReading(bookID: initialSelection, defaults: defaults)
        }

        func makeSource(format: BookFileType = .epub, body: String = "Incoming book.") throws -> URL {
            let generated: URL
            if format == .pdf {
                generated = try PdfFixture.createSinglePage(title: "Incoming PDF", author: "Fixture Author")
            } else {
                generated = try EpubFixture.createWithChapter(body: body)
            }
            defer { try? FileManager.default.removeItem(at: generated) }
            let source = root.appendingPathComponent(generated.lastPathComponent)
            try FileManager.default.moveItem(at: generated, to: source)
            sourceContents[source] = try Data(contentsOf: source)
            return source
        }

        func reloadedLibrary() -> LibraryStore {
            LibraryStore(defaults: defaults, importDirectory: root.appendingPathComponent("library"))
        }

        func assertDurableImport(from source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
            let imported = try XCTUnwrap(library.books.first { $0.displayFilename == source.lastPathComponent },
                                         file: file, line: line)
            let persisted = try XCTUnwrap(reloadedLibrary().books.first { $0.id == imported.id }, file: file, line: line)
            let copy = try LibraryBookmarkAccess.resolveBookBookmark(persisted.bookmark).url
            let original = try XCTUnwrap(sourceContents[source], file: file, line: line)
            XCTAssertTrue(copy.resolvingSymlinksInPath().path.hasPrefix(root.path + "/library/"), file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: copy), original, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: source), original, file: file, line: line)
        }

        func cleanUp() {
            try? library.flushPersistenceSync()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
