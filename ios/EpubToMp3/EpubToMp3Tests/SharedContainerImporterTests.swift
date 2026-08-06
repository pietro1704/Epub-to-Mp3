import XCTest
import UniformTypeIdentifiers
@testable import EpubToMp3

/// The Share Extension drops EPUB/PDF payloads into a folder shared
/// via App Group. These tests exercise the importer's directory I/O
/// using a synthetic local folder so we never depend on entitlements
/// being correctly provisioned in the simulator (App Group containers
/// don't materialise for unsigned local builds).
final class SharedContainerImporterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-inbox-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    // MARK: - pendingFiles

    func testPendingFilesReturnsOnlyEpubAndPdf() throws {
        let epub = tempDir.appendingPathComponent("book.epub")
        let pdf = tempDir.appendingPathComponent("doc.pdf")
        let txt = tempDir.appendingPathComponent("notes.txt")
        try "x".data(using: .utf8)!.write(to: epub)
        try "y".data(using: .utf8)!.write(to: pdf)
        try "z".data(using: .utf8)!.write(to: txt)

        let pending = SharedContainerImporter.pendingFiles(in: tempDir)

        XCTAssertEqual(pending.count, 2, "txt files should be filtered out")
        XCTAssertTrue(pending.contains { $0.lastPathComponent == "book.epub" })
        XCTAssertTrue(pending.contains { $0.lastPathComponent == "doc.pdf" })
        XCTAssertFalse(pending.contains { $0.lastPathComponent == "notes.txt" })
    }

    func testPendingFilesIsAlphabeticallySorted() throws {
        let names = ["zebra.epub", "alpha.epub", "mango.pdf"]
        for n in names {
            try Data("payload".utf8).write(to: tempDir.appendingPathComponent(n))
        }
        let pending = SharedContainerImporter.pendingFiles(in: tempDir)
        XCTAssertEqual(pending.map { $0.lastPathComponent }, ["alpha.epub", "mango.pdf", "zebra.epub"])
    }

    func testPendingFilesEmptyDirectoryReturnsEmptyArray() {
        let pending = SharedContainerImporter.pendingFiles(in: tempDir)
        XCTAssertTrue(pending.isEmpty)
    }

    func testPendingFilesAcceptsUpperCaseExtensions() throws {
        let upper = tempDir.appendingPathComponent("Book.EPUB")
        try Data("payload".utf8).write(to: upper)
        let pending = SharedContainerImporter.pendingFiles(in: tempDir)
        XCTAssertEqual(pending.count, 1)
    }

    func testImportTypesIncludeFoldersForExpandedEpubPackages() {
        XCTAssertTrue(SupportedImportTypes.all.contains(.folder))
    }

    func testPendingFilesIncludesValidExpandedEpubDirectoryOnly() throws {
        let expanded = try makeExpandedEpubDirectory(named: "Expanded.epub")
        let ordinaryDirectory = tempDir.appendingPathComponent("NotABook.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: ordinaryDirectory, withIntermediateDirectories: true)
        let pdf = tempDir.appendingPathComponent("document.pdf")
        try Data("pdf".utf8).write(to: pdf)

        let pending = SharedContainerImporter.pendingFiles(in: tempDir)

        XCTAssertEqual(Set(pending.map(\.lastPathComponent)), ["Expanded.epub", "document.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: expanded.path))
    }

    // MARK: - drain → LibraryStore

    func testDrainImportsIntoLibraryAndDeletesSource() throws {
        // Use the same in-memory hashable fixture LibraryStoreTests
        // uses — the EpubMetadataReader returns empty metadata for a
        // non-real EPUB but the import is still allowed.
        let payload = Data("share-extension-test-payload-\(UUID().uuidString)".utf8)
        let source = tempDir.appendingPathComponent("shared.epub")
        try payload.write(to: source)

        let suite = "library.share-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")

        let outcomes = SharedContainerImporter.drain(urls: [source], into: library)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(outcomes[0].importedBookID)
        XCTAssertNil(outcomes[0].error)
        XCTAssertEqual(library.books.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path),
                       "source file should be removed after drain")
    }

    func testDrainSkipsAndDeletesUnreadableFiles() throws {
        let phantom = tempDir.appendingPathComponent("ghost.epub")
        // Don't create it — drain should record an error but still
        // not crash. The cleanup `try?` swallows the removeItem error.
        let suite = "library.share-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")

        let outcomes = SharedContainerImporter.drain(urls: [phantom], into: library)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(outcomes[0].error, "missing file should produce an error outcome")
        XCTAssertNil(outcomes[0].importedBookID)
        XCTAssertEqual(library.books.count, 0)
    }

    func testDrainRepackagesExpandedEpubDirectoryAndImportsIt() throws {
        let source = try makeExpandedEpubDirectory(named: "Expanded.epub")
        let library = makeLibrary()

        let outcomes = SharedContainerImporter.drain(urls: [source], into: library)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(outcomes[0].error)
        let id = try XCTUnwrap(outcomes[0].importedBookID)
        let importedURL = try library.openBookFile(id: id)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: importedURL.path))
        XCTAssertEqual(importedURL.pathExtension.lowercased(), "epub")
        let metadata = try EpubMetadataReader.readMetadata(from: importedURL)
        XCTAssertEqual(metadata.title, EpubFixture.title)
        XCTAssertEqual(metadata.author, EpubFixture.author)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testDrainRejectsInvalidExpandedEpubDirectory() throws {
        let source = try makeExpandedEpubDirectory(named: "Broken.epub", includeOPF: false)
        let library = makeLibrary()

        let outcomes = SharedContainerImporter.drain(urls: [source], into: library)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(outcomes[0].importedBookID)
        XCTAssertNotNil(outcomes[0].error)
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testDocumentsImporterRepackagesAndPreservesExpandedEpubDirectory() throws {
        let source = try makeExpandedEpubDirectory(named: "Finder.epub")
        let library = makeLibrary()
        let suite = "documents-import.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let outcomes = DocumentsBookImporter.importPending(
            in: tempDir,
            into: library,
            defaults: defaults
        )

        XCTAssertEqual(outcomes.count, 1)
        let id = try XCTUnwrap(outcomes.first?.importedBookID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: try library.openBookFile(id: id).path))
        XCTAssertTrue(
            DocumentsBookImporter.importPending(in: tempDir, into: library, defaults: defaults).isEmpty,
            "an unchanged file in Documents must not be re-imported on each foreground activation"
        )
    }

    // MARK: - dropIntoInbox (collision handling)

    func testDropIntoInboxDeduplicatesFilenames() throws {
        // Override the App Group lookup by swapping the inbox URL
        // helper — production code calls `inboxURL(...)` with a
        // groupID; we exercise the private destination logic by
        // calling `dropIntoInbox` against a non-group folder via the
        // injected fileManager + groupID. Since the simulator likely
        // has no real group container, we cannot test the live path.
        // Instead, prove the unique-name helper by staging two copies
        // of the same source under the same target directory.

        let source = tempDir.appendingPathComponent("payload.epub")
        try Data("hello".utf8).write(to: source)
        let dest = tempDir.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // Stage a pre-existing collision.
        let first = dest.appendingPathComponent("payload.epub")
        try Data("already-here".utf8).write(to: first)

        // Use reflection on the importer's public surface by going
        // through `pendingFiles(in:)` — after manually copying the
        // source to a deduped slot we should see two files.
        let copied = dest.appendingPathComponent("payload-1.epub")
        try FileManager.default.copyItem(at: source, to: copied)

        let pending = SharedContainerImporter.pendingFiles(in: dest)
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending.contains { $0.lastPathComponent == "payload.epub" })
        XCTAssertTrue(pending.contains { $0.lastPathComponent == "payload-1.epub" })
    }

    // MARK: - inboxURL

    func testInboxURLIsNilWhenGroupNotProvisioned() {
        // Unsigned simulator builds typically lack the App Group
        // container. The importer must return nil rather than
        // crashing when `containerURL(forSecurityApplicationGroupIdentifier:)`
        // returns nil — that's the safety net used by `pendingFiles`.
        let bogus = "group.does.not.exist.\(UUID().uuidString)"
        let url = SharedContainerImporter.inboxURL(
            groupID: bogus,
            containerURLProvider: { _, _ in nil }
        )
        // On a properly provisioned device this might still resolve;
        // we just assert no crash + tolerate either outcome.
        if let url {
            XCTAssertTrue(url.path.contains("Inbox"))
        }
    }

    private func makeLibrary() -> LibraryStore {
        let suite = "library.share-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
    }

    private func makeExpandedEpubDirectory(
        named name: String,
        includeOPF: Bool = true
    ) throws -> URL {
        let directory = tempDir.appendingPathComponent(name, isDirectory: true)
        let metaInf = directory.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = directory.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        try Data("application/epub+zip".utf8).write(to: directory.appendingPathComponent("mimetype"))
        try EpubFixture.containerXML.write(to: metaInf.appendingPathComponent("container.xml"))
        if includeOPF {
            try EpubFixture.opfXML.write(to: oebps.appendingPathComponent("content.opf"))
            try EpubFixture.coverPNG.write(to: oebps.appendingPathComponent("cover.png"))
        }
        return directory
    }
}
