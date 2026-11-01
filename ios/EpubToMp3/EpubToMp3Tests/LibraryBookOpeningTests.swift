#if os(macOS)
import AppKit
import Foundation
import XCTest
@testable import EpubToMp3

@MainActor
final class LibraryBookOpeningTests: XCTestCase {
    func testLegacyCopyAllowsMainActorHeartbeatAndPreservesSource() async throws {
        let manager = OpeningCopyFileManager()
        let fixture = try OpeningFixture(manager: manager)
        defer { fixture.cleanup() }
        let existing = try fixture.makeExistingCopy()
        manager.observeCopy {
            XCTAssertFalse(Thread.isMainThread, "Legacy file copies must run outside MainActor")
            let heartbeat = DispatchSemaphore(value: 0)
            Task { @MainActor in heartbeat.signal() }
            XCTAssertEqual(heartbeat.wait(timeout: .now() + 2), .success,
                           "The UI must remain responsive during the real copy")
        }
        let opened = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: opened.deletingLastPathComponent().path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(LibraryImportFiles.isAppOwnedLibraryURL(opened, baseDirectory: fixture.libraryRoot))
        XCTAssertEqual(try Data(contentsOf: opened), fixture.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: existing), OpeningFixture.existingBytes)
        XCTAssertNotEqual(fixture.store.books.first?.bookmark, fixture.book.bookmark)
        XCTAssertNotNil(fixture.store.books.first?.lastOpenedAt)
        let reopened = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        XCTAssertEqual(opened.resolvingSymlinksInPath(), reopened.resolvingSymlinksInPath())
    }

    func testFailedCopyPreservesBookmarkSourceAndExistingDurableFile() async throws {
        let manager = OpeningCopyFileManager()
        let fixture = try OpeningFixture(manager: manager)
        defer { fixture.cleanup() }
        let existing = try fixture.makeExistingCopy()
        manager.observeCopy { throw CocoaError(.fileReadNoPermission) }
        do {
            _ = try await fixture.store.openBookFileAsync(id: fixture.book.id)
            XCTFail("A failed copy must fail the open")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoPermission.rawValue) }
        XCTAssertEqual(fixture.store.books.first?.bookmark, fixture.book.bookmark)
        XCTAssertNil(fixture.store.books.first?.lastOpenedAt)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: existing), OpeningFixture.existingBytes)
        try fixture.assertNoAbandonedOpeningFiles()
    }

    func testBookmarkReplacementDuringCopyRejectsTheOldOpen() async throws {
        try await verifyInvalidation(.replaceBookmark)
    }

    func testRemovalDuringCopyRejectsTheOldOpen() async throws {
        try await verifyInvalidation(.remove)
    }

    func testRemovalAndReinsertionWithTheSameBookmarkRejectsTheOldOpen() async throws {
        try await verifyInvalidation(.removeAndReinsert)
    }

    func testCancellationDuringCopyDoesNotPublishOrOverwriteExistingFiles() async throws {
        try await verifyInvalidation(.cancel)
    }

    func testFileTypeChangeDuringCopyRejectsTheOldOpen() async throws {
        try await verifyInvalidation(.changeFileType)
    }

    func testAlreadyCancelledOpenDoesNotCreateACopy() async throws {
        let fixture = try OpeningFixture(manager: OpeningCopyFileManager())
        defer { fixture.cleanup() }
        let opening = Task { @MainActor in try await fixture.store.openBookFileAsync(id: fixture.book.id) }
        opening.cancel()
        do {
            _ = try await opening.value
            XCTFail("A cancelled request must not start preparing a file")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.libraryRoot.path))
        XCTAssertEqual(fixture.store.books.first?.bookmark, fixture.book.bookmark)
    }

    func testMetadataEditsDuringCopySurviveSuccessfulPublication() async throws {
        let manager = OpeningCopyFileManager()
        let fixture = try OpeningFixture(manager: manager)
        defer { fixture.cleanup() }
        manager.observeCopy {
            let release = DispatchSemaphore(value: 0)
            Task { @MainActor in
                var edited = fixture.book
                edited.title = "Edited while opening"
                fixture.store.update(edited)
                release.signal()
            }
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        }
        let opened = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        XCTAssertEqual(try Data(contentsOf: opened), fixture.sourceBytes)
        XCTAssertEqual(fixture.store.books.first?.title, "Edited while opening")
        XCTAssertNotNil(fixture.store.books.first?.lastOpenedAt)
    }

    func testReaderOpensTheMigratedLegacyBookWithoutPlayback() async throws {
        let manager = OpeningCopyFileManager()
        let fixture = try OpeningFixture(manager: manager)
        defer { fixture.cleanup() }
        let copied = expectation(description: "Reader performs the legacy migration")
        manager.observeCopy {
            XCTAssertFalse(Thread.isMainThread)
            copied.fulfill()
        }
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: fixture.defaults)))
        defer {
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            NSApp.setActivationPolicy(policy)
        }
        UserDefaults.standard.set(fixture.book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let controller = MacReaderViewController(library: fixture.store,
            settings: AppSettings(defaults: fixture.defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: fixture.defaults, storageKey: "bookmarks"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.contentMinSize = NSSize(width: 800, height: 700)
        window.setContentSize(NSSize(width: 800, height: 700))
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fulfillment(of: [copied], timeout: 5)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var rendered = ""
        for _ in 0..<300 {
            controller.view.layoutSubtreeIfNeeded()
            rendered = descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first?.string ?? ""
            if rendered.contains(fixture.suite) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(rendered.contains(fixture.suite), "The reader must show the migrated file's own content")
        XCTAssertFalse(player.isPlaying)
        let opened = try await fixture.store.openBookFileAsync(id: fixture.book.id)
        XCTAssertEqual(try Data(contentsOf: opened), fixture.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    }

    private enum Invalidation: Sendable { case replaceBookmark, changeFileType, remove, removeAndReinsert, cancel }
    @MainActor private final class OpenTask { var value: Task<URL, Error>? }

    private func verifyInvalidation(_ reason: Invalidation) async throws {
        let manager = OpeningCopyFileManager()
        let fixture = try OpeningFixture(manager: manager, bookID: reason == .removeAndReinsert ? "ui-test-book" : nil)
        defer { fixture.cleanup() }
        let existing = try fixture.makeExistingCopy()
        let replacementBookmark = try LibraryBookmarkAccess.makeBookmark(for: existing)
        let pending = OpenTask()
        manager.observeCopy {
            let release = DispatchSemaphore(value: 0)
            Task { @MainActor in
                switch reason {
                case .replaceBookmark:
                    var replacement = fixture.book
                    replacement.bookmark = replacementBookmark
                    fixture.store.update(replacement)
                case .changeFileType:
                    var replacement = fixture.book
                    replacement.fileType = .pdf
                    fixture.store.update(replacement)
                case .remove:
                    fixture.store.remove(id: fixture.book.id)
                case .removeAndReinsert:
                    fixture.store.remove(id: fixture.book.id)
                    // Recreate the entry with the same identity without doing synchronous I/O.
                    fixture.store.installUITestFixtureIfRequested(arguments: ["-uiTestFixture"])
                    fixture.store.update(fixture.book)
                case .cancel:
                    pending.value?.cancel()
                }
                release.signal()
            }
            XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        }
        pending.value = Task { @MainActor in try await fixture.store.openBookFileAsync(id: fixture.book.id) }
        do {
            _ = try await pending.value!.value
            XCTFail("An invalidated open must not publish its result")
        } catch {
            if reason == .cancel { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertTrue([404, 409].contains((error as NSError).code)) }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: existing), OpeningFixture.existingBytes)
        if reason == .replaceBookmark { XCTAssertEqual(fixture.store.books.first?.bookmark, replacementBookmark) }
        if reason == .remove { XCTAssertTrue(fixture.store.books.isEmpty) }
        try fixture.assertNoAbandonedOpeningFiles()
    }
}

private final class OpeningCopyFileManager: FileManager, @unchecked Sendable {
    private let actionLock = NSLock()
    private var action: (@Sendable () throws -> Void)?

    func observeCopy(_ callback: @escaping @Sendable () throws -> Void) {
        actionLock.withLock { action = callback }
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        let callback = actionLock.withLock { () -> (@Sendable () throws -> Void)? in
            defer { action = nil }
            return action
        }
        try callback?()
        try super.copyItem(at: source, to: destination)
    }
}

@MainActor
private final class OpeningFixture {
    static let existingBytes = Data("A newer durable copy must survive an obsolete open.".utf8)
    let suite = "legacy-open-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let libraryRoot: URL
    let source: URL
    let sourceBytes: Data
    let book: BookEntity
    let store: LibraryStore

    init(manager: FileManager, bookID: String? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        libraryRoot = root.appendingPathComponent("library")
        source = try EpubFixture.createWithChapter(body: "A legacy book with real chapter content. " + suite)
        sourceBytes = try Data(contentsOf: source)
        book = BookEntity(id: try bookID ?? LibraryImportFiles.contentHash(of: source), title: "Legacy book",
            bookmark: try LibraryBookmarkAccess.makeBookmark(for: source),
            displayFilename: source.lastPathComponent, addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        store = LibraryStore(defaults: defaults, defaultsKey: "library", fileManager: manager,
                             importDirectory: libraryRoot)
    }

    func makeExistingCopy() throws -> URL {
        let directory = libraryRoot.appendingPathComponent(book.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = directory.appendingPathComponent(source.lastPathComponent)
        try Self.existingBytes.write(to: existing)
        return existing
    }

    func assertNoAbandonedOpeningFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        let files = FileManager.default.enumerator(at: libraryRoot, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix(".opening-") }, file: file, line: line)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        ReaderProgressStore.evict(bookId: book.id)
        LocalFulltextCache.evict(bookId: book.id)
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
