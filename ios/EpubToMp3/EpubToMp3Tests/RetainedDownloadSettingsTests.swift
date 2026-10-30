#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

final class RetainedDownloadSettingsTests: XCTestCase {
    private var root: URL!
    private var artifacts: LocalAudioArtifactStore!
    private var storage: BookDownloadStorage!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        artifacts = LocalAudioArtifactStore(root: root.appendingPathComponent("artifacts"))
        storage = BookDownloadStorage(artifacts: artifacts, retainedRoot: root, downloads: AudiobookDownloads())
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func book(_ id: String, job: String) -> BookEntity {
        BookEntity(id: id, title: "Fixture \(id)", bookmark: Data([1]), displayFilename: "fixture.epub",
                   addedAt: .now, lastJobId: job, cachedOffline: true)
    }

    @discardableResult
    private func retain(_ job: String, manifestJob: String? = nil, filename: String = "chapter.mp3") throws -> URL {
        let directory = root.appendingPathComponent(job).appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audio = directory.appendingPathComponent(filename)
        try Data(repeating: 42, count: 128).write(to: audio)
        let manifest = AudiobookManifest(jobId: manifestJob ?? job, bookTitle: "Retained fixture",
            chapters: [.init(index: 0, title: "Chapter", mp3FileName: filename, mp3Bytes: 128, downloadedAt: .now)],
            totalBytes: 128, completedAt: .now)
        try JSONEncoder().encode(manifest).write(to: directory.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        return audio
    }

    @MainActor
    func testSettingsListsReaderRetainedAudioUsingLibraryBookIdentity() async throws {
        try retain("job-a")
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try defaults.set(JSONEncoder().encode([book("book-a", job: "job-a")]), forKey: "library.books.v1")
        let controller = LocalAudioDownloadsScreenController(library: LibraryStore(defaults: defaults),
            artifactStore: artifacts, retainedRoot: root, downloads: AudiobookDownloads())
        controller.loadViewIfNeeded()
        await controller.refreshDownloadedBooks()
        let cell = controller.tableView(controller.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(cell.accessibilityIdentifier, "settings.downloadedBook.book-a")
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.text, "Fixture book-a")
    }

    @MainActor
    func testOlderRemovalCannotClearNewerLibraryDownloadState() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try defaults.set(JSONEncoder().encode([book("book-a", job: "new-job")]), forKey: "library.books.v1")
        let library = LibraryStore(defaults: defaults)
        let controller = LocalAudioDownloadsScreenController(library: library, artifactStore: artifacts,
            removeAudio: { id in XCTAssertEqual(id, "book-a") }, retainedRoot: root, downloads: AudiobookDownloads())
        controller.loadViewIfNeeded()
        await controller.removeDownloadedAudio(for: .init(bookID: "book-a", title: "Old download",
            author: nil, chapterCount: 1, byteCount: 128), jobID: "old-job")
        XCTAssertEqual(library.books.first?.lastJobId, "new-job")
        XCTAssertEqual(library.books.first?.cachedOffline, true)
    }

    func testRemovalPreservesOtherJobSourceAndModelAndClearsBothStores() async throws {
        let selected = try retain("job-a"), other = try retain("job-b")
        let protected = root.appendingPathComponent("source-and-model")
        try Data([7, 8, 9]).write(to: protected)
        try await artifacts.prepare(bookID: "book-a", bookTitle: "Fixture book-a", author: nil,
                                    chapters: [.init(index: 1, title: "Older chapter")])
        let oldAudio = try await artifacts.canonicalURL(bookID: "book-a", chapterIndex: 1)
        try Data([1, 2]).write(to: oldAudio)
        try await artifacts.markAvailable(bookID: "book-a", chapterIndex: 1)
        try await artifacts.promote(bookID: "book-a", chapterIndex: 1)
        let books = [book("book-a", job: "job-a"), book("book-b", job: "job-b")]
        let entries = try await storage.entries(books: books)
        let entry = try XCTUnwrap(entries.first { $0.book.bookID == "book-a" })
        XCTAssertEqual(entry.book.byteCount, 130)
        XCTAssertEqual(entry.book.chapterCount, 2)
        try await storage.remove(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio.path))
        XCTAssertEqual(try Data(contentsOf: other), Data(repeating: 42, count: 128))
        XCTAssertEqual(try Data(contentsOf: protected), Data([7, 8, 9]))
        let remaining = try await storage.entries(books: books)
        XCTAssertEqual(remaining.map(\.book.bookID), ["book-b"])
    }

    func testMissingEmptyMismatchedAndAmbiguousJobsAreNotOfferedForDeletion() async throws {
        let missing = try retain("missing"), empty = try retain("empty")
        try FileManager.default.removeItem(at: missing)
        try Data().write(to: empty)
        try retain("mismatch", manifestJob: "other-job")
        try retain("ambiguous")
        try retain("escape", filename: "../outside.mp3")
        let books = [book("a", job: "missing"), book("b", job: "empty"), book("c", job: "mismatch"),
                     book("d", job: "ambiguous"), book("e", job: "ambiguous"), book("f", job: "escape"),
                     book("g", job: "../elsewhere")]
        let entries = try await storage.entries(books: books)
        XCTAssertTrue(entries.isEmpty)
    }

    func testChangedManifestIdentityRejectsRemovalAndPreservesFiles() async throws {
        let audio = try retain("job-a")
        let entries = try await storage.entries(books: [book("book-a", job: "job-a")])
        let entry = try XCTUnwrap(entries.first)
        try retain("job-a", manifestJob: "replacement-job")
        do { try await storage.remove(entry); XCTFail("Identity changes must reject deletion") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue) }
        XCTAssertEqual(try Data(contentsOf: audio), Data(repeating: 42, count: 128))
    }

    func testCancelledRemovalKeepsRetainedAudio() async throws {
        let audio = try retain("job-a")
        let entries = try await storage.entries(books: [book("book-a", job: "job-a")])
        let entry = try XCTUnwrap(entries.first)
        let storage = try XCTUnwrap(storage)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await storage.remove(entry)
        }
        do { try await operation.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: audio), Data(repeating: 42, count: 128))
    }
}
#endif
