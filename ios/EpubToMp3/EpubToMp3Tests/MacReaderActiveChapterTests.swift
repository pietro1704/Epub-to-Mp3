#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderActiveChapterTests: XCTestCase {
    func testPreparedChapterIsVisibleBeforeCatalogAndHydrationDoesNotRewind() async throws {
        try await verifyOpening(invalidateProjection: false)
    }

    func testChangedSourceDoesNotPresentStaleProjection() async throws {
        try await verifyOpening(invalidateProjection: true)
    }

    func testMismatchedCatalogRejectsQueuedProjectionRestore() async throws {
        try await verifyOpening(invalidateProjection: false, mismatchWithQueuedRestore: true)
    }

    func testAppearanceChangeDuringRestoreDoesNotLeaveOpeningPending() async throws {
        try await verifyOpening(invalidateProjection: false, deferredAppearance: true)
    }

    func testClosingDuringHydrationPersistsTheVisibleSnapshotPosition() async throws {
        try await verifyOpening(invalidateProjection: false, closeDuringHydration: true)
    }

    private func verifyOpening(invalidateProjection: Bool, mismatchWithQueuedRestore: Bool = false,
                               deferredAppearance: Bool = false, closeDuringHydration: Bool = false) async throws {
        let id = "active-chapter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        let book = BookEntity(id: id, title: "Active chapter", bookmark: Data([1]),
                              displayFilename: "active.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let active = String(repeating: "The complete saved chapter remains readable.\n", count: 220)
        var payload = EbookFulltext(jobId: id, bookTitle: "Active chapter", bookAuthor: "Author", chapters: [
            .init(index: 3, name: "Previous", text: String(repeating: "Previous chapter.\n", count: 120),
                  html: nil, css: nil, charCount: nil, segments: nil),
            .init(index: 7, name: "Active", text: active, html: nil, css: nil, charCount: nil, segments: nil)
        ])
        let source = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(payload).write(to: source, options: .atomic)
        let store = PreparedReaderChapterStore(directory: root.appendingPathComponent("chapters"))
        try await store.write(bookID: id, chapterOrdinal: 1, fulltextURL: source)
        if invalidateProjection || mismatchWithQueuedRestore {
            payload = EbookFulltext(jobId: id, bookTitle: "Changed book", bookAuthor: "Author", chapters: [
                payload.chapters[0], .init(index: 7, name: "Changed", text: "Replacement readable chapter.",
                    html: nil, css: nil, charCount: nil, segments: nil)])
            if invalidateProjection { try encoder.encode(payload).write(to: source, options: .atomic) }
        }
        let expected = payload
        let sourceBytes = mismatchWithQueuedRestore ? try encoder.encode(payload) : try Data(contentsOf: source)
        var scheduledRestores: [@MainActor () -> Void] = []
        var release: AsyncStream<Void>.Continuation!
        let gate = AsyncStream<Void> { release = $0 }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            release.finish(); player.stop()
            for (key, value) in zip(keys, prior) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: id); LocalFulltextCache.evict(bookId: id)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        ReaderProgressStore.save(bookId: id, chapterIndex: 1, offsetFraction: 0.6)
        UserDefaults.standard.set(id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        let settings = AppSettings(defaults: defaults)
        let controller = MacReaderViewController(library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            settings: settings, player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedChapterStore: store, preparedFulltextReader: { _ in
                for await _ in gate { }
                if mismatchWithQueuedRestore { try? sourceBytes.write(to: source, options: .atomic) }
                return expected
            }, initialPositionScheduler: { operation in
                if mismatchWithQueuedRestore || deferredAppearance { scheduledRestores.append(operation) }
                else { DispatchQueue.main.async { operation() } }
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.layoutIfNeeded(); controller.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let text = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        func observed(_ transition: LatencyObservation.Transition) -> Bool {
            LatencyObservationStore.shared.snapshot().contains {
                !known.contains($0.id) && $0.records.contains { $0.transition == transition }
            }
        }
        if mismatchWithQueuedRestore || deferredAppearance {
            for _ in 0..<200 {
                if scheduledRestores.count == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(scheduledRestores.count, 1)
            XCTAssertEqual(text.string, active)
            if deferredAppearance {
                settings.readerFontSize += 1
                scheduledRestores.first?()
            }
        }
        if !invalidateProjection && !mismatchWithQueuedRestore {
            for _ in 0..<200 {
                if observed(.readableContent) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(observed(.readableContent), "The real chapter must paint without complete-book decoding")
            XCTAssertEqual(text.string, active)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 6)
            let distance = text.frame.height - scroll.contentView.bounds.height
            XCTAssertEqual(scroll.contentView.bounds.origin.y, distance * 0.6, accuracy: 2)
        } else if invalidateProjection {
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(text.string.isEmpty, "Changed source must invalidate the old chapter projection")
        }
        XCTAssertFalse(observed(.controlsUsable), "Catalog-dependent controls are not ready during blocked hydration")
        if closeDuringHydration {
            let distance = text.frame.height - scroll.contentView.bounds.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: distance * 0.4))
            controller.viewWillDisappear()
            XCTAssertEqual(ReaderProgressStore.read(bookId: id)?.offsetFraction ?? -1, 0.4, accuracy: 0.001)
        }
        let before = scroll.contentView.bounds.origin.y
        release.finish()
        if mismatchWithQueuedRestore {
            for _ in 0..<200 {
                if scheduledRestores.count == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(scheduledRestores.count, 2)
            scheduledRestores.first?()
            XCTAssertFalse(observed(.controlsUsable), "An old snapshot callback must not finalize a mismatched catalog")
            scheduledRestores.last?()
        }
        for _ in 0..<200 {
            if observed(.controlsUsable) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observed(.controlsUsable))
        XCTAssertEqual(text.string, expected.chapters[1].text)
        if !invalidateProjection && !mismatchWithQueuedRestore {
            XCTAssertEqual(scroll.contentView.bounds.origin.y, before, accuracy: 2)
            XCTAssertEqual(text.onPageTap?(false), true)
            // Move explicitly to the previous chapter only after the complete catalog exists.
            scroll.contentView.scroll(to: .zero)
            XCTAssertEqual(text.onPageTap?(false), true)
            XCTAssertEqual(text.string, expected.chapters[0].text)
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }
}
#endif
