import XCTest
@testable import EpubToMp3

/// Exercises the shared removal sequence. The Rust output and local-audio
/// stores use temporary roots; the legacy download root is redirected through
/// `AudiobookDownloadStorage.rootOverrideForTesting`, and the static reader
/// caches are reached with per-test unique identities.
@MainActor
final class LibraryBookRemovalTests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var previousLegacyRoot: URL?
    /// Unique per test: the prepared-text, font and reading-position caches are
    /// not redirected, so fixed identities could match a real book.
    private var suffix = ""

    override func setUp() async throws {
        suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        suiteName = "LibraryBookRemovalTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        previousLegacyRoot = AudiobookDownloadStorage.rootOverrideForTesting
        AudiobookDownloadStorage.rootOverrideForTesting = root.appendingPathComponent("Audiobooks")
    }

    override func tearDown() async throws {
        if let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let item as URL in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
            }
        }
        try? FileManager.default.removeItem(at: root)
        AudiobookDownloadStorage.rootOverrideForTesting = previousLegacyRoot
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRemovesEveryStoreOfTheBookAndKeepsAnotherBook() async throws {
        let fixture = try await makeFixture(bookIDs: [id("Target"), id("Other")])
        try await fixture.removal.remove(bookID: id("Target"), legacyJobID: "job-" + id("Target"))

        XCTAssertEqual(fixture.library.books.map(\.id), [id("Other")])
        XCTAssertTrue(fixture.bookmarks.bookmarks(for: id("Target")).isEmpty)
        XCTAssertEqual(fixture.bookmarks.bookmarks(for: id("Other")).count, 1)
        XCTAssertFalse(exists(fixture.rustOutputs[id("Target")]!))
        XCTAssertFalse(exists(fixture.localAudio[id("Target")]!))
        // `FulltextStore.evict(jobId:)` recreates the emptied legacy job folder.
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: fixture.legacyFolders[id("Target")]!.path),
                       [])
        XCTAssertTrue(exists(fixture.rustOutputs[id("Other")]!))
        XCTAssertTrue(exists(fixture.localAudio[id("Other")]!))
        XCTAssertTrue(exists(fixture.legacyFolders[id("Other")]!))
    }

    /// Owner decision 2026-11-20: removing a book also deletes what the app derived
    /// or the listener set for that book only: prepared reader chapters and
    /// rendered archives, pronunciations and language corrections.
    func testAlsoRemovesPreparedChaptersPronunciationsAndLanguageFixesOfThatBookOnly() async throws {
        let fixture = try await makeFixture(bookIDs: [id("Target"), id("Other")])
        let signature = String(repeating: "a", count: 64)
        for (store, directory) in [(fixture.renderings, fixture.renderingsDirectory),
                                   (PreparedChapterArchiveStore(directory: fixture.readerDirectory), fixture.readerDirectory)] {
            for bookID in [id("Target"), id("Other")] {
                for chapter in [0, 7] { try await store.write(Data([9]), bookID: bookID, chapterIndex: chapter, signature: signature) }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
        }
        let pronunciations = BookPronunciationStore(defaults: defaults)
        let corrections = BookLanguageCorrections(defaults: defaults)
        for bookID in [id("Target"), id("Other")] {
            try pronunciations.save(try BookPronunciationDictionary.parse("Tolkien = Tólquien"), bookID: bookID)
            try corrections.set("en", bookID: bookID)
            try corrections.set("fr", bookID: bookID, passage: PassageLanguageCorrection(chapterIndex: 1, start: 0, end: 4, language: "fr"))
        }

        try await fixture.removal.remove(bookID: id("Target"), legacyJobID: "job-" + id("Target"))

        for store in [fixture.renderings, PreparedChapterArchiveStore(directory: fixture.readerDirectory)] {
            for chapter in [0, 7] {
                let removed = await store.read(bookID: id("Target"), chapterIndex: chapter)
                let kept = await store.read(bookID: id("Other"), chapterIndex: chapter)
                XCTAssertNil(removed)
                XCTAssertNotNil(kept)
            }
        }
        XCTAssertEqual(pronunciations.load(bookID: id("Target")), BookPronunciationDictionary())
        XCTAssertEqual(pronunciations.load(bookID: id("Other")).rules.count, 1)
        XCTAssertEqual(try corrections.decision(bookID: id("Target")), BookLanguageDecision())
        let other = try corrections.decision(bookID: id("Other"))
        XCTAssertEqual(other.bookLanguage, "en")
        XCTAssertEqual(other.passages.count, 1)
    }

    func testLocalAudioFailureLeavesTheBookAndLaterStoresInPlace() async throws {
        let fixture = try await makeFixture(bookIDs: [id("Target")])
        let locked = fixture.localAudio[id("Target")]!.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data([1]).write(to: locked.appendingPathComponent("held.mp3"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        do {
            try await fixture.removal.remove(bookID: id("Target"), legacyJobID: "job-" + id("Target"))
            XCTFail("A local-audio failure must reach the caller")
        } catch {}

        XCTAssertFalse(exists(fixture.rustOutputs[id("Target")]!), "Converted audio is removed first")
        XCTAssertTrue(exists(fixture.legacyFolders[id("Target")]!))
        XCTAssertEqual(fixture.bookmarks.bookmarks(for: id("Target")).count, 1)
        XCTAssertEqual(fixture.library.books.map(\.id), [id("Target")])
    }

    func testBusyConvertedAudioStoreRemovesNothing() async throws {
        let fixture = try await makeFixture(bookIDs: [id("Target")])
        // A removal waiting for a live writer keeps the output store in maintenance.
        let blocker = try await fixture.convertedAudio.begin(bookID: id("Blocker"), jobID: "blocker", cancel: {})
        let pending = Task { try await fixture.convertedAudio.removeAudio(bookID: id("Blocker")) }
        var busy = false
        for attempt in 0..<100 {
            do {
                let probe = try await fixture.convertedAudio.begin(bookID: id("Probe"), jobID: "probe-\(attempt)",
                                                                   cancel: {})
                await fixture.convertedAudio.finish(probe)
            } catch { busy = true; break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(busy, "The blocking removal must hold maintenance")

        do {
            try await fixture.removal.remove(bookID: id("Target"), legacyJobID: "job-" + id("Target"))
            XCTFail("A busy output store must reject the removal")
        } catch {}
        await fixture.convertedAudio.finish(blocker)
        _ = try? await pending.value

        XCTAssertTrue(exists(fixture.rustOutputs[id("Target")]!))
        XCTAssertTrue(exists(fixture.localAudio[id("Target")]!))
        XCTAssertTrue(exists(fixture.legacyFolders[id("Target")]!))
        XCTAssertEqual(fixture.bookmarks.bookmarks(for: id("Target")).count, 1)
        XCTAssertEqual(fixture.library.books.map(\.id), [id("Target")])
    }

    // MARK: - Fixture

    private struct Fixture {
        let removal: LibraryBookRemoval
        let library: LibraryStore
        let bookmarks: BookmarkStore
        let convertedAudio: RustConversionOutputStore
        let rustOutputs: [String: URL]
        let localAudio: [String: URL]
        let legacyFolders: [String: URL]
        let renderings: PreparedChapterArchiveStore
        let renderingsDirectory: URL
        let readerDirectory: URL
    }

    private func makeFixture(bookIDs: [String]) async throws -> Fixture {
        let convertedAudio = RustConversionOutputStore(root: root.appendingPathComponent("Rust", isDirectory: true))
        let localRoot = root.appendingPathComponent("Local", isDirectory: true)
        let books = bookIDs.map {
            BookEntity(id: $0, title: $0, bookmark: Data([1]), displayFilename: "\($0).epub",
                       addedAt: .now, lastJobId: "job-\($0)")
        }
        defaults.set(try JSONEncoder().encode(books), forKey: "library.books.v1")
        let library = LibraryStore(defaults: defaults)
        let bookmarks = BookmarkStore(defaults: defaults)
        var rustOutputs: [String: URL] = [:]
        var localAudio: [String: URL] = [:]
        var legacyFolders: [String: URL] = [:]
        for bookID in bookIDs {
            let lease = try await convertedAudio.begin(bookID: bookID, jobID: "rust-\(bookID)", cancel: {})
            try Data([1]).write(to: lease.outputDirectory.appendingPathComponent("chapter.mp3"))
            await convertedAudio.finish(lease)
            rustOutputs[bookID] = lease.outputDirectory
            try LocalAudioArtifactFixture.seed(root: localRoot, bookID: bookID,
                chapters: [.init(index: 0, title: "Chapter", audio: Data([2]))])
            localAudio[bookID] = LocalAudioArtifactFixture.files(root: localRoot).bookDirectory(bookID: bookID)
            let legacy = AudiobookDownloadStorage.audiobooksRoot().appendingPathComponent("job-\(bookID)")
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data([3]).write(to: legacy.appendingPathComponent("chapter.mp3"))
            legacyFolders[bookID] = legacy
            bookmarks.addBookmark(bookId: bookID, chapterIndex: 0, chapterTitle: "One")
        }
        let renderingsDirectory = root.appendingPathComponent("PreparedChapters", isDirectory: true)
        let readerDirectory = root.appendingPathComponent("PreparedReaderChapters", isDirectory: true)
        let renderings = PreparedChapterArchiveStore(directory: renderingsDirectory)
        let removal = LibraryBookRemoval(library: library, bookmarks: bookmarks, convertedAudio: convertedAudio,
                                         localAudio: LocalAudioArtifactStore(root: localRoot),
                                         preparedReader: PreparedReaderChapterStore(directory: readerDirectory),
                                         preparedRenderings: renderings,
                                         pronunciations: BookPronunciationStore(defaults: defaults),
                                         languageCorrections: BookLanguageCorrections(defaults: defaults))
        return Fixture(removal: removal, library: library, bookmarks: bookmarks, convertedAudio: convertedAudio,
                       rustOutputs: rustOutputs, localAudio: localAudio, legacyFolders: legacyFolders,
                       renderings: renderings, renderingsDirectory: renderingsDirectory, readerDirectory: readerDirectory)
    }

    private func id(_ name: String) -> String { name + suffix }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
