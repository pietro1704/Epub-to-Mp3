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
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey,
                    "reader.recentTool.v1"]
        let prior = keys.map { UserDefaults.standard.object(forKey: $0) }
        let book = BookEntity(id: id, title: "Active chapter", bookmark: Data([1]),
                              displayFilename: "active.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let active = String(repeating: "The complete saved chapter remains readable.\n", count: 220)
        var payload = EbookFulltext(jobId: id, bookTitle: "Active chapter", bookAuthor: "Author", chapters: [
            .init(index: 3, name: "Previous", text: String(repeating: "Previous chapter.\n", count: 120),
                  html: nil, css: nil, charCount: nil, segments: nil),
            .init(index: 7, name: "Active", text: active, html: nil, css: nil, charCount: nil, segments: nil,
                  footnotes: [.init(number: "1", text: "An authored note.")])
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
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard)
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
        let toolPreference = ReaderToolPreference()
        toolPreference.recent = .footnotes
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
        func footnotesControl() -> MacReaderToolControl? { MacReaderToolControl.find(.footnotes, in: controller.view) }
        func footnotesShortcutIsVisible() -> Bool {
            descendants(controller.view).contains {
                $0.accessibilityIdentifier() == ReaderTool.footnotes.accessibilityIdentifier && !$0.isHidden
            }
        }
        XCTAssertNil(footnotesControl())
        XCTAssertFalse(footnotesShortcutIsVisible())
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
                if observed(.readableContent) && observed(.controlsUsable) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(observed(.readableContent), "The real chapter must paint without complete-book decoding")
            XCTAssertTrue(observed(.controlsUsable),
                           "A source-bound complete chapter index and active chapter make audio controls usable during body hydration")
            XCTAssertEqual(text.string, active)
            XCTAssertNotNil(footnotesControl(), "The prepared chapter already owns its footnotes")
            XCTAssertTrue(footnotesShortcutIsVisible())
            XCTAssertEqual(UserDefaults.standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 6)
            // Restoring lands on the start of the whole-line page that holds the saved position.
            let distance = text.frame.height - scroll.contentView.bounds.height
            let starts = MacReaderTextLayout.pageStarts(of: text, viewportHeight: scroll.contentView.bounds.height)
            let page = starts[MacReaderTextLayout.pageIndex(of: distance * 0.6, in: starts)]
            XCTAssertGreaterThan(page, distance * 0.6 - scroll.contentView.bounds.height)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, page, accuracy: 2)
        } else if invalidateProjection {
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(text.string.isEmpty, "Changed source must invalidate the old chapter projection")
        }
        if invalidateProjection || mismatchWithQueuedRestore {
            XCTAssertFalse(observed(.controlsUsable), "An invalidated projection cannot make controls usable")
        }
        if closeDuringHydration {
            let distance = text.frame.height - scroll.contentView.bounds.height
            scroll.contentView.scroll(to: NSPoint(x: 0, y: distance * 0.4))
            controller.viewWillDisappear()
            XCTAssertEqual(ReaderProgressStore.read(bookId: id)?.offsetFraction ?? -1, 0.4, accuracy: 0.001)
        }
        let before = scroll.contentView.bounds.origin.y
        var topArea = scroll.contentView.documentVisibleRect
        topArea.origin.y += scroll.contentView.bounds.height / 2
        topArea.size.height = 1
        let passageBefore = (scroll.documentView as? NSTextView)
            .flatMap { MacReaderTextLayout.characterRange(in: topArea, of: $0)?.location }
        release.finish()
        if mismatchWithQueuedRestore {
            try sourceBytes.write(to: source, options: .atomic)
            scheduledRestores.first?()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertFalse(observed(.controlsUsable), "A changed source must invalidate the old snapshot before readiness")
            for _ in 0..<200 {
                if scheduledRestores.count == 2 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(scheduledRestores.count, 2)
            XCTAssertFalse(observed(.controlsUsable), "An old snapshot callback must not finalize a mismatched catalog")
            scheduledRestores.last?()
        }
        for _ in 0..<200 {
            if observed(.controlsUsable) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(observed(.controlsUsable))
        XCTAssertEqual(text.string, expected.chapters[1].text)
        if invalidateProjection || mismatchWithQueuedRestore {
            XCTAssertNil(footnotesControl(), "The replacement chapter has no footnotes")
            XCTAssertFalse(footnotesShortcutIsVisible())
        }
        if !invalidateProjection && !mismatchWithQueuedRestore {
            for _ in 0..<200 {
                if controller.numberOfRows(in: NSTableView()) == expected.chapters.count { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(controller.numberOfRows(in: NSTableView()), expected.chapters.count,
                           "Chapter navigation waits until the complete catalog hydrates")
            // A deferred font change relays out the lines, so the reader follows the text instead of the offset.
            if deferredAppearance {
                let character = try XCTUnwrap(passageBefore)
                let visible = try XCTUnwrap(MacReaderTextLayout.characterRange(in: scroll.contentView.documentVisibleRect, of: text))
                XCTAssertTrue(NSLocationInRange(character, visible), "\(character) left \(visible)")
            } else {
                XCTAssertEqual(scroll.contentView.bounds.origin.y, before, accuracy: 2)
            }
            let previouslyAvailable = try XCTUnwrap(footnotesControl())
            XCTAssertEqual(previouslyAvailable.identifier, ReaderTool.footnotes.accessibilityIdentifier)
            XCTAssertTrue(footnotesShortcutIsVisible())
            XCTAssertEqual(text.onPageTap?(false), true)
            // Move explicitly to the previous chapter only after the complete catalog exists.
            scroll.contentView.scroll(to: .zero)
            XCTAssertEqual(text.onPageTap?(false), true)
            XCTAssertEqual(text.string, expected.chapters[0].text)
            XCTAssertNil(footnotesControl())
            XCTAssertFalse(footnotesShortcutIsVisible())
            XCTAssertEqual(toolPreference.recent, .footnotes)
            // A menu retained across a chapter change must not present stale notes.
            XCTAssertTrue(previouslyAvailable.send())
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, text.frame.height - scroll.contentView.bounds.height)))
            XCTAssertEqual(text.onPageTap?(true), true)
            XCTAssertEqual(text.string, expected.chapters[1].text)
            XCTAssertNotNil(footnotesControl())
            XCTAssertTrue(footnotesShortcutIsVisible())
        }
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }
}
#endif
