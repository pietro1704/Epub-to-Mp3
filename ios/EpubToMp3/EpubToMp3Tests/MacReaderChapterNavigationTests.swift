#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderChapterNavigationTests: XCTestCase {
    func testBackwardFromChapterStartLandsAtPreviousChapterEnd() async throws {
        try await verifyChapterBoundary(openTableOfContents: false)
    }

    func testBackwardChapterCrossingAfterOpeningTableOfContents() async throws {
        try await verifyChapterBoundary(openTableOfContents: true)
    }

    private func verifyChapterBoundary(openTableOfContents: Bool) async throws {
        let identifier = "chapter-crossing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey, "readerProgress.v1", "readerWarmBookIDs.v1",
                    "reader.recentTool.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: identifier)
        }
        let book = BookEntity(id: identifier, title: "Chapter crossing", bookmark: Data([1]),
                              displayFilename: "crossing.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let longText = String(repeating: "A complete line of previous chapter text.\n", count: 200)
        let currentText = String(repeating: "A complete line of current chapter text.\n", count: 240)
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Previous", text: longText, html: nil, css: nil,
                  charCount: longText.count, segments: nil),
            .init(index: 2, name: "Current", text: currentText, html: nil, css: nil,
                  charCount: currentText.count, segments: nil),
        ])
        let preparedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: preparedDirectory))
        let chapterStore = PreparedReaderChapterStore(directory: preparedDirectory.appendingPathComponent("chapters"))
        defer { try? FileManager.default.removeItem(at: preparedDirectory) }
        ReaderProgressStore.save(bookId: identifier, chapterIndex: 1, offsetFraction: 0)
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let controlsReady = expectation(description: "The initial reader restoration must finish before navigating.")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedRenderer: renderer, preparedChapterStore: chapterStore,
            preparedFulltextReader: { _ in payload }, preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in
                if name == "controls_usable" { controlsReady.fulfill() }
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 700, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.layoutIfNeeded()
        await fulfillment(of: [controlsReady], timeout: 5)
        func findText(in view: NSView) -> MacReaderTextView? {
            if let text = view as? MacReaderTextView { return text }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        let text = try XCTUnwrap(findText(in: controller.view))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        func openContents() throws {
            XCTAssertTrue(try XCTUnwrap(MacReaderToolControl.find(.contents, in: controller.view)).send())
        }
        if openTableOfContents { try openContents() }
        XCTAssertEqual(text.string, currentText)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertEqual(text.onPageTap?(false), true)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(text.string, longText)
        let proposedEnd = max(0, text.frame.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, scroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.origin.y, proposedEnd + 1)
        let container = try XCTUnwrap(text.textContainer)
        let usedRect = try XCTUnwrap(text.layoutManager).usedRect(for: container)
        let visibleRect = scroll.contentView.documentVisibleRect
        XCTAssertLessThanOrEqual(
            usedRect.maxY,
            visibleRect.maxY + 0.5,
            "Every laid-out glyph must remain inside the final visible document rect."
        )
        let pageStarts = MacReaderTextLayout.pageStarts(of: text, viewportHeight: scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, try XCTUnwrap(pageStarts.last), accuracy: 1,
                       "The previous chapter must open on its last whole-line page.")
        let backwardProgress = try XCTUnwrap(ReaderProgressStore.read(bookId: identifier))
        XCTAssertEqual(backwardProgress.chapterIndex, 0)
        XCTAssertEqual(backwardProgress.offsetFraction, 1, accuracy: 0.001)
        XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 0)
        // Playback starts at the first visible glyph; reading progress is the scroll extent.
        var glyphViewport = scroll.contentView.documentVisibleRect
        glyphViewport.origin.y -= text.textContainerInset.height
        let manager = try XCTUnwrap(text.layoutManager)
        let visibleGlyphs = manager.glyphRange(forBoundingRect: glyphViewport, in: container)
        XCTAssertGreaterThan(visibleGlyphs.length, 0)
        let visibleAnchor = Double(manager.characterIndexForGlyph(at: visibleGlyphs.location)) / Double(text.string.utf16.count)
        XCTAssertEqual(standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey), visibleAnchor, accuracy: 0.001)
        XCTAssertEqual(text.onPageTap?(true), true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(text.string, currentText)
        XCTAssertGreaterThan(text.frame.height - scroll.contentView.bounds.height, scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        let forwardProgress = try XCTUnwrap(ReaderProgressStore.read(bookId: identifier))
        XCTAssertEqual(forwardProgress.chapterIndex, 1)
        XCTAssertEqual(forwardProgress.offsetFraction, 0, accuracy: 0.001)
        XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 1)
        XCTAssertEqual(standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey), 0, accuracy: 0.001)

        if openTableOfContents {
            // A subsequent selection must still navigate after highlight synchronization.
            try openContents()
            func findChapterTable(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, table.delegate is MacReaderContentsPresentation { return table }
                return view.subviews.lazy.compactMap { findChapterTable(in: $0) }.first
            }
            let table = try XCTUnwrap(NSApp.windows.compactMap { candidate in
                candidate.contentView.flatMap { findChapterTable(in: $0) }
            }.first)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(text.string, longText)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
            XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 0)
        }
    }
}
#endif
