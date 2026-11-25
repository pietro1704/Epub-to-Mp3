#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

private final class RemovalNotices: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [String?] = []
    var bookIDs: [String?] { lock.lock(); defer { lock.unlock() }; return received }
    func append(_ bookID: String?) { lock.lock(); received.append(bookID); lock.unlock() }
}

/// Pins what "Remove from library" deletes through the real Mac library menu.
/// The menu action uses the app's shared stores, so every seeded item lives
/// under a fresh UUID identity and is removed again in teardown; the legacy
/// `Audiobooks/<jobId>` root is redirected to a temporary directory.
@MainActor
final class LibraryBookRemovalCharacterizationTests: XCTestCase {
    private struct Seed {
        let bookID: String
        let jobID: String
        let rustOutput: URL
        let localAudioBook: URL
        let legacyAudiobook: URL
        let legacyFulltext: URL
        let readerFulltext: URL
        let readerFonts: URL
    }

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var legacyRoot: URL!
    private var previousLegacyRoot: URL?
    private var cleanupURLs: [URL] = []
    private var cleanupProgressIDs: [String] = []

    override func setUp() async throws {
        suiteName = "LibraryBookRemoval-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        previousLegacyRoot = AudiobookDownloadStorage.rootOverrideForTesting
        legacyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        AudiobookDownloadStorage.rootOverrideForTesting = legacyRoot
        cleanupURLs = [legacyRoot]
    }

    override func tearDown() async throws {
        for url in cleanupURLs {
            makeWritable(url)
            try? FileManager.default.removeItem(at: url)
        }
        cleanupProgressIDs.forEach { ReaderProgressStore.evict(bookId: $0) }
        AudiobookDownloadStorage.rootOverrideForTesting = previousLegacyRoot
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMacMenuRemovalClearsEveryStoreOfTheBookAndPreservesTheOtherBook() async throws {
        let target = try await seed()
        let other = try await seed()
        let source = try writeFile(FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suiteName)-source.epub"), bytes: [5, 6, 7])
        let library = try makeLibrary(target: target, other: other)
        let bookmarks = BookmarkStore(defaults: defaults)
        seedBookmarks(bookmarks, for: [target.bookID, other.bookID])
        let removalNotices = RemovalNotices()
        let observer = NotificationCenter.default.addObserver(
            forName: RustConversionOutputStore.willRemoveAudio, object: nil, queue: nil
        ) { notice in removalNotices.append(notice.userInfo?["bookID"] as? String) }
        defer { NotificationCenter.default.removeObserver(observer) }

        let controller = makeController(library: library, bookmarks: bookmarks)
        try chooseRemove(bookID: target.bookID, in: controller)
        await waitUntil { !library.books.contains { $0.id == target.bookID } }

        XCTAssertEqual(library.books.map(\.id), [other.bookID])
        XCTAssertEqual(LibraryStore(defaults: defaults).books.map(\.id), [other.bookID],
                       "The removal is persisted to the library index")
        XCTAssertTrue(bookmarks.bookmarks(for: target.bookID).isEmpty)
        XCTAssertEqual(bookmarks.bookmarks(for: other.bookID).count, 2)
        XCTAssertTrue(BookmarkStore(defaults: defaults).bookmarks(for: target.bookID).isEmpty)
        XCTAssertNil(ReaderProgressStore.read(bookId: target.bookID))
        XCTAssertNotNil(ReaderProgressStore.read(bookId: other.bookID))
        assertRemoved(target)
        assertPresent(other)
        XCTAssertEqual(try Data(contentsOf: source), Data([5, 6, 7]),
                       "The book's source file is never deleted")
        XCTAssertTrue(removalNotices.bookIDs.contains(target.bookID),
                      "Playback of the removed book is stopped through willRemoveAudio")
    }

    /// Owner decision 2026-11-20: the Mac asks before removing, like iOS.
    func testMacMenuRemovalAsksFirstAndCancelKeepsEverything() async throws {
        let target = try await seed()
        let library = try makeLibrary(entries: [(target, target.jobID)])
        let bookmarks = BookmarkStore(defaults: defaults)
        seedBookmarks(bookmarks, for: [target.bookID])
        let confirmations = RemovalNotices()
        let controller = makeController(library: library, bookmarks: bookmarks, answer: false,
                                        confirmations: confirmations)
        try chooseRemove(bookID: target.bookID, in: controller)
        await waitUntil { !confirmations.bookIDs.isEmpty }
        // Give a removal that should not happen time to run.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(confirmations.bookIDs, [library.books.first?.resolvedTitle], "asked once, with the book's title")
        XCTAssertEqual(library.books.map(\.id), [target.bookID])
        XCTAssertEqual(bookmarks.bookmarks(for: target.bookID).count, 2)
        assertPresent(target)
    }

    func testMacMenuRemovalWithoutLegacyJobKeepsLegacyJobFolders() async throws {
        let target = try await seed()
        let library = try makeLibrary(entries: [(target, nil)])
        let bookmarks = BookmarkStore(defaults: defaults)
        let controller = makeController(library: library, bookmarks: bookmarks)
        try chooseRemove(bookID: target.bookID, in: controller)
        await waitUntil { library.books.isEmpty }

        XCTAssertTrue(library.books.isEmpty)
        XCTAssertFalse(exists(target.rustOutput))
        XCTAssertFalse(exists(target.localAudioBook))
        XCTAssertFalse(exists(target.readerFulltext))
        XCTAssertFalse(exists(target.readerFonts))
        XCTAssertTrue(exists(target.legacyAudiobook), "Only the entity's lastJobId selects a legacy folder")
        XCTAssertTrue(exists(target.legacyFulltext))
    }

    func testLocalAudioFailureStopsAfterConvertedAudioAndReportsTheError() async throws {
        let target = try await seed()
        let library = try makeLibrary(entries: [(target, target.jobID)])
        let bookmarks = BookmarkStore(defaults: defaults)
        seedBookmarks(bookmarks, for: [target.bookID])
        // A read-only child makes removing the book's local-audio folder fail.
        let locked = target.localAudioBook.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        _ = try writeFile(locked.appendingPathComponent("held.mp3"), bytes: [1])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        let controller = makeController(library: library, bookmarks: bookmarks)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            window.contentViewController = nil
        }
        try chooseRemove(bookID: target.bookID, in: controller)
        await waitUntil { window.attachedSheet != nil }

        let alert = try XCTUnwrap(window.attachedSheet, "A failed removal presents an error sheet")
        XCTAssertTrue(alert.contentView.map { containsText(L10n.string("settings.storageRemovalFailedTitle"), in: $0) } ?? false)
        XCTAssertFalse(exists(target.rustOutput), "Converted audio is removed before local audio")
        XCTAssertTrue(exists(locked.appendingPathComponent("held.mp3")))
        XCTAssertTrue(exists(target.legacyAudiobook), "Nothing after the failed step runs")
        XCTAssertTrue(exists(target.legacyFulltext))
        XCTAssertTrue(exists(target.readerFulltext))
        XCTAssertTrue(exists(target.readerFonts))
        XCTAssertEqual(bookmarks.bookmarks(for: target.bookID).count, 2)
        XCTAssertNotNil(ReaderProgressStore.read(bookId: target.bookID))
        XCTAssertEqual(library.books.map(\.id), [target.bookID])
    }

    // MARK: - Fixture

    private func seed() async throws -> Seed {
        let bookID = "RemovalBook\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let jobID = "removal-job-\(UUID().uuidString)"
        let lease = try await RustConversionOutputStore.shared.begin(bookID: bookID, jobID: jobID, cancel: {})
        _ = try writeFile(lease.outputDirectory.appendingPathComponent("chapter.mp3"), bytes: [1, 2])
        await RustConversionOutputStore.shared.finish(lease)
        let localRoot = LocalAudioArtifactStore.defaultRoot()
        try LocalAudioArtifactFixture.seed(root: localRoot, bookID: bookID,
            chapters: [.init(index: 0, title: "Chapter", audio: Data([3, 4]))])
        let localAudioBook = LocalAudioArtifactFixture.files(root: localRoot).bookDirectory(bookID: bookID)
        let legacyAudiobook = legacyRoot.appendingPathComponent(jobID, isDirectory: true)
        _ = try writeFile(legacyAudiobook.appendingPathComponent("chapters/0.mp3"), bytes: [9])
        let legacyFulltext = try writeFile(try XCTUnwrap(FulltextStore.fulltextURL(for: jobID)), bytes: [8])
        let readerFulltext = try writeFile(try XCTUnwrap(LocalFulltextCache.storageURL(bookId: bookID)), bytes: [7])
        let support = ApplicationSupportRoot.url()
        let readerFonts = support.appendingPathComponent("EpubToMp3/ReaderFonts-v1/\(bookID)", isDirectory: true)
        _ = try writeFile(readerFonts.appendingPathComponent("font.ttf"), bytes: [6])
        ReaderProgressStore.save(bookId: bookID, chapterIndex: 2, offsetFraction: 0.5)
        cleanupProgressIDs.append(bookID)
        cleanupURLs += [lease.outputDirectory, localAudioBook, readerFulltext, readerFonts]
        return Seed(bookID: bookID, jobID: jobID, rustOutput: lease.outputDirectory,
                    localAudioBook: localAudioBook, legacyAudiobook: legacyAudiobook,
                    legacyFulltext: legacyFulltext, readerFulltext: readerFulltext, readerFonts: readerFonts)
    }

    private func makeLibrary(target: Seed, other: Seed) throws -> LibraryStore {
        try makeLibrary(entries: [(target, target.jobID), (other, other.jobID)])
    }

    private func makeLibrary(entries: [(Seed, String?)]) throws -> LibraryStore {
        let books = entries.map { seed, jobID in
            BookEntity(id: seed.bookID, title: seed.bookID, bookmark: Data([1]),
                       displayFilename: "\(seed.bookID).epub", addedAt: .now, lastJobId: jobID)
        }
        defaults.set(try JSONEncoder().encode(books), forKey: "library.books.v1")
        let library = LibraryStore(defaults: defaults)
        XCTAssertEqual(Set(library.books.map(\.id)), Set(books.map(\.id)))
        return library
    }

    private func seedBookmarks(_ store: BookmarkStore, for bookIDs: [String]) {
        for bookID in bookIDs {
            store.addBookmark(bookId: bookID, chapterIndex: 0, chapterTitle: "One")
            store.addBookmark(bookId: bookID, chapterIndex: 1, chapterTitle: "Two", startChar: 1, endChar: 4,
                              selectedText: "text")
        }
    }

    /// `confirmations` records each title the confirmation was asked for; the
    /// listener's answer is `answer` (the real app shows an NSAlert sheet).
    private func makeController(library: LibraryStore, bookmarks: BookmarkStore, answer: Bool = true,
                                confirmations: RemovalNotices? = nil) -> MacLibraryViewController {
        let controller = MacLibraryViewController(library: library, bookmarkStore: bookmarks,
            onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in },
            confirmRemoval: { title, _ in confirmations?.append(title); return answer })
        _ = controller.view
        return controller
    }

    /// Invokes the same menu item the user chooses on a library card.
    private func chooseRemove(bookID: String, in controller: MacLibraryViewController) throws {
        let title = L10n.string("library.removeFromLibrary")
        for index in 0..<10 {
            guard let menu = controller.collectionView(NSCollectionView(),
                                                       menuForItemsAt: [IndexPath(item: index, section: 0)]),
                  let item = menu.items.first(where: { $0.title == title }) else { break }
            guard item.representedObject as? String == bookID else { continue }
            let action = try XCTUnwrap(item.action)
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        XCTFail("No remove menu item for \(bookID)")
    }

    private func assertRemoved(_ seed: Seed, file: StaticString = #filePath, line: UInt = #line) {
        for url in [seed.rustOutput, seed.localAudioBook, seed.legacyFulltext,
                    seed.readerFulltext, seed.readerFonts] {
            XCTAssertFalse(exists(url), "\(url.lastPathComponent) must be removed", file: file, line: line)
        }
        // Current behavior: `FulltextStore.evict(jobId:)` resolves its path through
        // `fulltextURL(for:)`, which recreates the job folder after the legacy
        // download was deleted. Only an empty directory remains.
        XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: seed.legacyAudiobook.path), [],
                       "The legacy job folder keeps no files", file: file, line: line)
    }

    private func assertPresent(_ seed: Seed, file: StaticString = #filePath, line: UInt = #line) {
        for url in [seed.rustOutput, seed.localAudioBook, seed.legacyAudiobook, seed.legacyFulltext,
                    seed.readerFulltext, seed.readerFonts] {
            XCTAssertTrue(exists(url), "\(url.lastPathComponent) must be kept", file: file, line: line)
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @discardableResult
    private func writeFile(_ url: URL, bytes: [UInt8]) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeWritable(_ url: URL) {
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
        }
    }

    private func containsText(_ text: String, in view: NSView) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text { return true }
        return view.subviews.contains { containsText(text, in: $0) }
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<250 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the removal to finish", file: file, line: line)
    }
}
#endif
