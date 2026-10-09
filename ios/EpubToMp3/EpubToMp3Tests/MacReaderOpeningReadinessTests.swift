#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderOpeningReadinessTests: XCTestCase {
    @MainActor private final class ColdWriteSession {
        weak var controller: MacReaderViewController?
    }

    func testColdOpenPersistsOffMainWhileUIRemainsResponsive() async throws {
        try await verifyColdWrite(clearSelectionDuringWrite: false)
    }

    func testClearingSelectionDuringColdWriteRejectsStalePresentation() async throws {
        try await verifyColdWrite(clearSelectionDuringWrite: true)
    }

    private func verifyColdWrite(clearSelectionDuringWrite: Bool) async throws {
        let suite = "cold-reader-write-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let body = String(repeating: "A readable cold chapter. ", count: 200) + suite
        let source = try EpubFixture.createWithChapter(body: body)
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let sourceBytes = try Data(contentsOf: source)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: book.id)
            LocalFulltextCache.evict(bookId: book.id)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        UserDefaults.standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let heartbeat = expectation(description: "UI responds during persistence")
        let persisted = expectation(description: "Complete fulltext persisted")
        let session = ColdWriteSession()
        let controller = MacReaderViewController(library: library,
            settings: AppSettings(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedFulltextReader: { _ in nil }, preparedFulltextWriter: { payload, id in
                XCTAssertFalse(Thread.isMainThread, "Cold-open persistence must not block the UI thread")
                let release = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    if clearSelectionDuringWrite { session.controller?.setBook(nil) }
                    heartbeat.fulfill()
                    release.signal()
                }
                XCTAssertEqual(release.wait(timeout: .now() + 2), .success,
                               "MainActor must execute while the real persistence caller is blocked")
                LocalFulltextCache.save(payload, bookId: id)
                persisted.fulfill()
            })
        session.controller = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        await fulfillment(of: [heartbeat, persisted], timeout: 5)
        let cache = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: book.id))
        let durable = try PropertyListDecoder().decode(EbookFulltext.self, from: Data(contentsOf: cache))
        XCTAssertTrue(durable.chapters.contains { $0.text.contains(body) })
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertFalse(player.isPlaying)
        if clearSelectionDuringWrite {
            try await Task.sleep(nanoseconds: 50_000_000)
            let text = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first)
            XCTAssertTrue(text.string.isEmpty, "A completed old write must not restore a deselected book")
            XCTAssertNil(UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey))
        }
    }

    func testReadinessRequiresSavedPositionToBeApplied() async throws {
        try await verifyReadiness(closeBeforeRestore: false)
    }

    func testClosingBeforeRestoreDoesNotOverwriteSavedPassage() async throws {
        try await verifyReadiness(closeBeforeRestore: true)
    }

    func testReloadBeforeRestoreRejectsOldCompletionWithoutLosingSavedPassage() async throws {
        try await verifyReadiness(closeBeforeRestore: false, reloadBeforeRestore: true)
    }

    func testPageTurnWaitsForRestoreAndDoesNotReapplySavedOffsetLater() async throws {
        try await verifyReadiness(closeBeforeRestore: false, pageTurnBeforeRestore: true)
    }

    private func verifyReadiness(closeBeforeRestore: Bool, reloadBeforeRestore: Bool = false,
                                 pageTurnBeforeRestore: Bool = false) async throws {
        let id = "reader-readiness-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let key = ReaderSessionState.currentlyReadingBookIDKey
        let keys = [key, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: id)
            LocalFulltextCache.evict(bookId: id)
            defaults.removePersistentDomain(forName: id)
        }
        let book = BookEntity(id: id, title: "Readiness", bookmark: Data([1]),
                              displayFilename: "readiness.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let payload = EbookFulltext(jobId: id, bookTitle: "Readiness", bookAuthor: nil,
            chapters: [.init(index: 1, name: "Saved chapter",
                text: String(repeating: "A complete readable line.\n", count: 400),
                html: nil, css: nil, charCount: nil, segments: nil)])
        LocalFulltextCache.save(payload, bookId: id)
        ReaderProgressStore.save(bookId: id, chapterIndex: 0, offsetFraction: 0.6)
        UserDefaults.standard.set(id, forKey: key)
        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            settings: AppSettings(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSScrollView }
            .first { $0.documentView is NSTextView })
        func ready() -> Bool {
            LatencyObservationStore.shared.snapshot().contains {
                !known.contains($0.id) && $0.records.contains { $0.transition == .controlsUsable }
            }
        }
        func assertPosition() throws {
            let document = try XCTUnwrap(scroll.documentView)
            let distance = document.frame.height - scroll.contentView.bounds.height
            XCTAssertGreaterThan(distance, 100)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, distance * 0.6, accuracy: 2,
                           "Readiness cannot precede restoration of the saved passage")
        }
        // Do not yield before checking: the old implementation reports ready
        // synchronously but schedules position restoration for a later runloop.
        if ready() { try assertPosition() }
        if reloadBeforeRestore { controller.setBook(id) }
        let text = try XCTUnwrap(scroll.documentView as? MacReaderTextView)
        if pageTurnBeforeRestore {
            XCTAssertEqual(text.onPageTap?(true), true)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        }
        if closeBeforeRestore {
            controller.viewWillDisappear()
            XCTAssertEqual(ReaderProgressStore.read(bookId: id)?.offsetFraction, 0.6,
                           "Closing before restoration must not persist the temporary zero offset")
        }
        for _ in 0..<200 {
            if ready() { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(ready())
        try assertPosition()
        if pageTurnBeforeRestore {
            let restored = scroll.contentView.bounds.origin.y
            XCTAssertEqual(text.onPageTap?(true), true)
            try await Task.sleep(nanoseconds: 20_000_000)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, restored)
        }
        if reloadBeforeRestore {
            let journeys = LatencyObservationStore.shared.snapshot().filter { !known.contains($0.id) }
            XCTAssertEqual(journeys.count, 2)
            XCTAssertEqual(journeys.first?.records.map(\.transition), [.openRequested, .cancelled])
            XCTAssertEqual(journeys.last?.records.map(\.transition), [.openRequested, .readableContent, .controlsUsable])
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
#endif
