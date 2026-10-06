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
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: identifier)
            LocalFulltextCache.evict(bookId: identifier)
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
        LocalFulltextCache.save(payload, bookId: identifier)
        ReaderProgressStore.save(bookId: identifier, chapterIndex: 1, offsetFraction: 0)
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 700, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil }
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        func findText(in view: NSView) -> MacReaderTextView? {
            if let text = view as? MacReaderTextView { return text }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        let text = try XCTUnwrap(findText(in: controller.view))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        func findTOCButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.action == NSSelectorFromString("showTOC:") {
                return button
            }
            return view.subviews.lazy.compactMap { findTOCButton(in: $0) }.first
        }
        if openTableOfContents {
            try XCTUnwrap(findTOCButton(in: controller.view)).performClick(nil)
        }
        XCTAssertEqual(text.string, currentText)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertEqual(text.onPageTap?(false), true)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(text.string, longText)
        let end = max(0, text.frame.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(end, scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, end, accuracy: 1)
        let backwardProgress = try XCTUnwrap(ReaderProgressStore.read(bookId: identifier))
        XCTAssertEqual(backwardProgress.chapterIndex, 0)
        XCTAssertEqual(backwardProgress.offsetFraction, 1, accuracy: 0.001)
        XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 0)
        XCTAssertEqual(standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey), 1, accuracy: 0.001)
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
            try XCTUnwrap(findTOCButton(in: controller.view)).performClick(nil)
            func findChapterTable(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, table.delegate === controller { return table }
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
