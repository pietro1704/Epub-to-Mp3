#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// PARITY-MAC-READER-3: like the iPhone, a paginated page says "x of y" and a switch turns it off.
@MainActor
final class MacReaderPageNumbersTests: XCTestCase {
    func testPaginatedPageShowsItsNumberAndFollowsPageTurns() async throws {
        try await withReader { textView, indicator in
            let label = try XCTUnwrap(indicator(), "missing page indicator")
            let first = label.stringValue
            let total = try XCTUnwrap((2...500).first { first == L10n.string("reader.pageOf", 1, $0) }, "shown: \(first)")
            XCTAssertEqual(textView.onPageTap?(true), true)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(label.stringValue, L10n.string("reader.pageOf", 2, total))
            XCTAssertEqual(textView.onPageTap?(false), true)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(label.stringValue, first)
            let scroll = try XCTUnwrap(textView.enclosingScrollView)
            let root = try XCTUnwrap(label.window?.contentView)
            XCTAssertFalse(label.convert(label.bounds, to: root).intersects(scroll.convert(scroll.bounds, to: root)),
                           "the indicator must never cover text")
        }
    }

    func testIndicatorFollowsTheSwitchAndTheLayout() async throws {
        try await withReader(showsNumbers: false) { _, indicator in
            XCTAssertNil(indicator(), "switched off")
        }
        try await withReader(layout: .scrolling) { _, indicator in
            XCTAssertNil(indicator(), "scrolling has no pages")
        }
    }

    func testAppearancePanelOffersThePageNumbersSwitch() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Synthetic text.")])
        harness.installTeardown(in: self)
        let settings = harness.settings
        settings.readerLayout = .paginated
        let before = settings.readerShowPageNumbers
        let popover = NSPopover()
        let presentation = MacReaderSettingsPresentation(settings: settings, popover: popover)
        presentation.prepareForTesting()
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "readerSettings.showPageNumbers" { return button }
            let children = (view as? NSScrollView)?.documentView.map { [$0] } ?? view.subviews
            return children.lazy.compactMap(find).first
        }
        let root = try XCTUnwrap(popover.contentViewController?.view)
        let toggle = try XCTUnwrap(find(root), "missing page numbers switch")
        XCTAssertEqual(toggle.state, before ? .on : .off)
        toggle.performClick(nil)
        XCTAssertEqual(settings.readerShowPageNumbers, !before)
    }

    private func withReader(
        showsNumbers: Bool = true, layout: ReaderLayout = .paginated,
        inspect: @MainActor (MacReaderTextView, () -> NSTextField?) async throws -> Void
    ) async throws {
        let identifier = "reader-pages-\(UUID().uuidString)"
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
        let book = BookEntity(id: identifier, title: "Synthetic pages", bookmark: Data([1]),
                              displayFilename: "pages.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let text = String(repeating: "A synthetic sentence that fills the reading column with words. ", count: 600)
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Pages", text: text, html: nil, css: nil, charCount: text.count, segments: nil),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: directory))
        let chapterStore = PreparedReaderChapterStore(directory: directory.appendingPathComponent("chapters"))
        defer { try? FileManager.default.removeItem(at: directory) }
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = layout
        settings.readerShowPageNumbers = showsNumbers
        let ready = expectation(description: "reader ready")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedRenderer: renderer, preparedChapterStore: chapterStore,
            preparedFulltextReader: { _ in payload }, preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in if name == "controls_usable" { ready.fulfill() } })
        let size = NSSize(width: 1200, height: 700)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.layoutIfNeeded()
        await fulfillment(of: [ready], timeout: 5)
        window.layoutIfNeeded()
        func findText(in view: NSView) -> MacReaderTextView? {
            if let text = view as? MacReaderTextView { return text }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        func find<T: NSView>(in view: NSView, where matches: (T) -> Bool) -> T? {
            if let found = view as? T, matches(found) { return found }
            return view.subviews.lazy.compactMap { find(in: $0, where: matches) }.first
        }
        let textView: MacReaderTextView = try XCTUnwrap(find(in: controller.view) { _ in true })
        try await inspect(textView) {
            find(in: controller.view) { (field: NSTextField) in
                field.accessibilityIdentifier() == "reader.pageIndicator" && !field.isHiddenOrHasHiddenAncestor
            }
        }
    }
}
#endif
