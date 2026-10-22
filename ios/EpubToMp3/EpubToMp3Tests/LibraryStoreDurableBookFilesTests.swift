import XCTest

@testable import EpubToMp3

extension LibraryStoreTests {
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

        let durable = try LibraryImportFiles.persistImportedFileForLibrary(
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

    func testFailedDurableReplacementPreservesPreviousFile() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let picked = root.appendingPathComponent("picked", isDirectory: true)
        try manager.createDirectory(at: picked, withIntermediateDirectories: true)
        let source = picked.appendingPathComponent("Book.epub")
        let previous = Data("Previous valid book".utf8)
        try previous.write(to: source)
        let storage = root.appendingPathComponent("library", isDirectory: true)
        let durable = try LibraryImportFiles.persistImportedFileForLibrary(
            originalURL: source, id: "replacement", fileType: .epub, baseDirectory: storage
        )
        let replacement = Data("Replacement book".utf8)
        try replacement.write(to: source)

        for failReplacement in [false, true] {
            let failingManager = FailingImportCopyFileManager()
            failingManager.failReplacement = failReplacement
            XCTAssertThrowsError(try LibraryImportFiles.persistImportedFileForLibrary(
                originalURL: source, id: "replacement", fileType: .epub,
                fileManager: failingManager, baseDirectory: storage
            ))
            XCTAssertEqual(try Data(contentsOf: durable), previous)
            XCTAssertEqual(try Data(contentsOf: source), replacement)
            XCTAssertEqual(try manager.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path), ["Book.epub"])
        }
    }

    func testDurableSelfReimportPreservesTheImportedFile() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-self-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Book.epub")
        let contents = Data("Valid imported book".utf8)
        try contents.write(to: source)
        let storage = root.appendingPathComponent("library", isDirectory: true)
        let durable = try LibraryImportFiles.persistImportedFileForLibrary(
            originalURL: source, id: "self-import", fileType: .epub, baseDirectory: storage
        )
        let reimported = try LibraryImportFiles.persistImportedFileForLibrary(
            originalURL: durable, id: "self-import", fileType: .epub, baseDirectory: storage
        )
        XCTAssertEqual(reimported, durable)
        XCTAssertEqual(try Data(contentsOf: durable), contents)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path), ["Book.epub"])
    }

    func testSuccessfulDurableReplacementPreservesBookmarkDestination() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-successful-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Book.epub")
        try Data("Previous book".utf8).write(to: source)
        let storage = root.appendingPathComponent("library", isDirectory: true)
        let durable = try LibraryImportFiles.persistImportedFileForLibrary(
            originalURL: source, id: "replacement", fileType: .epub, baseDirectory: storage
        )
        let bookmark = try durable.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let replacement = Data("New complete book".utf8)
        try replacement.write(to: source)
        let replaced = try LibraryImportFiles.persistImportedFileForLibrary(
            originalURL: source, id: "replacement", fileType: .epub, baseDirectory: storage
        )
        XCTAssertEqual(replaced, durable)
        XCTAssertEqual(try Data(contentsOf: durable), replacement)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.standardizedFileURL.path, durable.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: resolved), replacement)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path), ["Book.epub"])
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
