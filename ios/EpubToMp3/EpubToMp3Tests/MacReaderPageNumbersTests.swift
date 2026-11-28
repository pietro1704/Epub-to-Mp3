#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// PARITY-MAC-READER-3: like the iPhone, a paginated page says "x of y" and a switch turns it off.
@MainActor
final class MacReaderPageNumbersTests: XCTestCase {
    private var settingsUnderTest: AppSettings?

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

    /// MAC-READER-PAGINATED-SCROLLBAR: like the iPhone, only the scrolling layout has a scroll bar, also after
    /// switching the layout with the book open.
    func testOnlyTheScrollingLayoutHasAScrollBar() async throws {
        for opening in [ReaderLayout.paginated, .scrolling] {
            try await withReader(layout: opening) { textView, _ in
                let scroll = try XCTUnwrap(textView.enclosingScrollView)
                let settings = try XCTUnwrap(settingsUnderTest)
                let other: ReaderLayout = opening == .paginated ? .scrolling : .paginated
                for layout in [opening, other, opening] {
                    settings.readerLayout = layout
                    try await Task.sleep(nanoseconds: 300_000_000)
                    XCTAssertEqual(scroll.hasVerticalScroller, layout == .scrolling,
                                   "opened \(opening.rawValue), now \(layout.rawValue)")
                }
            }
        }
    }

    /// MAC-READER-PAGE-BOTTOM-CLIP: a one-column page holds whole lines only, the next page starts at the next line,
    /// and the page count and the scroll snap use the same page starts.
    func testOneColumnPagesShowWholeLinesOnceEach() async throws {
        try await withReader(columns: 1) { textView, indicator in
            let scroll = try XCTUnwrap(textView.enclosingScrollView)
            let manager = try XCTUnwrap(textView.layoutManager)
            let container = try XCTUnwrap(textView.textContainer)
            manager.ensureLayout(for: container)
            let originY = textView.textContainerOrigin.y
            var lines: [NSRect] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, _, _ in
                lines.append(rect.offsetBy(dx: 0, dy: originY))
            }
            XCTAssertGreaterThan(lines.count, 40)
            /// What the person can read: the viewport minus the bottom mask.
            @MainActor func readable() -> (top: CGFloat, bottom: CGFloat) {
                let visible = scroll.contentView.documentVisibleRect
                let mask = textView.subviews.first { $0.accessibilityIdentifier() == "reader.pageMask" && !$0.isHidden }
                return (visible.minY, min(visible.maxY, mask?.frame.minY ?? visible.maxY))
            }
            var shown: [Int] = []
            var offsets: [CGFloat] = []
            var labels: [String] = []
            while offsets.count < 200 {
                try await Task.sleep(nanoseconds: 150_000_000)
                let (top, bottom) = readable()
                offsets.append(scroll.contentView.bounds.origin.y)
                labels.append(indicator()?.stringValue ?? "")
                for (index, line) in lines.enumerated() where line.maxY > top + 0.5 && line.minY < bottom - 0.5 {
                    XCTAssertTrue(line.minY >= top - 0.5 && line.maxY <= bottom + 0.5,
                                  "page \(offsets.count): line \(index) is cut")
                    shown.append(index)
                }
                if shown.last == lines.count - 1 { break }
                XCTAssertEqual(textView.onPageTap?(true), true)
            }
            XCTAssertEqual(shown, Array(lines.indices), "every line is shown once, in order")
            XCTAssertEqual(labels, (1...labels.count).map { L10n.string("reader.pageOf", $0, labels.count) })

            XCTAssertEqual(textView.onPageTap?(false), true)
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offsets[offsets.count - 2], accuracy: 0.5,
                           "turning back returns to the previous page start")
        }
    }

    /// MAC-READER-IMAGE-AFTER-HEADING-CLIP: a figure scaled to the page height that follows a heading must be shown
    /// whole on one page, never cut at the bottom of the heading's page.
    func testTallFigureAfterAHeadingIsNeverCut() async throws {
        try await withReader(columns: 1) { textView, _ in
            let scroll = try XCTUnwrap(textView.enclosingScrollView)
            let window = try XCTUnwrap(textView.window)
            let attachment = NSTextAttachment()
            attachment.image = NSImage(size: NSSize(width: 653, height: 2200), flipped: false) { rect in
                NSColor.systemOrange.setFill(); rect.fill()
                return true
            }
            let chapter = NSMutableAttributedString(string: "Synthetic heading\n",
                                                    attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
            chapter.append(NSAttributedString(attachment: attachment))
            chapter.append(NSAttributedString(
                string: "\n" + String(repeating: "Text after the figure. ", count: 400),
                attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            textView.textStorage?.setAttributedString(chapter)
            // A real resize drives the reader's own fit and page mask.
            window.setContentSize(NSSize(width: 1100, height: 660))
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            let manager = try XCTUnwrap(textView.layoutManager)
            let container = try XCTUnwrap(textView.textContainer)
            manager.ensureLayout(for: container)
            let index = (textView.string as NSString).range(of: "\u{FFFC}").location
            let glyph = manager.glyphIndexForCharacter(at: index)
            let origin = textView.textContainerOrigin
            let location = manager.location(forGlyphAt: glyph)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let figure = NSRect(x: origin.x + line.minX + location.x,
                                y: origin.y + line.minY + location.y - attachment.bounds.height,
                                width: attachment.bounds.width, height: attachment.bounds.height)
            var wholeViews = 0
            for page in 1...3 {
                let visible = scroll.contentView.documentVisibleRect
                let mask = textView.subviews.first { $0.accessibilityIdentifier() == "reader.pageMask" && !$0.isHidden }
                let bottom = min(visible.maxY, mask?.frame.minY ?? visible.maxY)
                if figure.maxY > visible.minY + 0.5, figure.minY < bottom - 0.5 {
                    let whole = figure.minY >= visible.minY - 0.5 && figure.maxY <= bottom + 0.5
                    XCTAssertTrue(whole, "page \(page): figure \(figure) is cut by the readable area \(visible.minY)...\(bottom)")
                    if whole { wholeViews += 1 }
                }
                XCTAssertEqual(textView.onPageTap?(true), true)
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            XCTAssertEqual(wholeViews, 1, "the figure is shown whole exactly once")
        }
    }

    /// MAC-FONT-CHANGE-KEEPS-TEXT-POSITION: like the iPhone, a font change keeps the passage on screen.
    func testFontSizeChangeKeepsThePassageOnScreen() async throws {
        for layout in [ReaderLayout.paginated, .scrolling] {
            try await withReader(layout: layout, columns: 1) { textView, _ in
                let settings = try XCTUnwrap(self.settingsUnderTest)
                let scroll = try XCTUnwrap(textView.enclosingScrollView)
                for _ in 1...6 {
                    XCTAssertEqual(textView.onPageTap?(true), true)
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                @MainActor func visibleCharacters() throws -> NSRange {
                    var area = scroll.contentView.documentVisibleRect
                    area.origin.y += 1
                    area.size.height -= 1
                    return try XCTUnwrap(MacReaderTextLayout.characterRange(in: area, of: textView))
                }
                let passage = try visibleCharacters().location
                let origin = scroll.contentView.bounds.origin.y
                let size = settings.readerFontSize
                for step in [2, 2, -2] {
                    settings.readerFontSize += step
                    try await Task.sleep(nanoseconds: 400_000_000)
                    let shown = try visibleCharacters()
                    XCTAssertTrue(NSLocationInRange(passage, shown),
                                  "\(layout), step \(step): character \(passage) left the screen, shown \(shown)")
                }
                settings.readerFontSize = size
                try await Task.sleep(nanoseconds: 400_000_000)
                XCTAssertEqual(scroll.contentView.bounds.origin.y, origin, accuracy: 1,
                               "\(layout): the original size must return to the original position")
            }
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

    /// PARITY-MAC-READER-6: the Mac offers Slide and None; the iPhone's Flip has no AppKit counterpart.
    func testAppearancePanelOffersSlideAndNoneOnlyForPaginatedPages() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Synthetic text.")])
        harness.installTeardown(in: self)
        let settings = harness.settings
        settings.readerLayout = .paginated
        settings.pageTurnStyle = .flip
        let popover = NSPopover()
        let presentation = MacReaderSettingsPresentation(settings: settings, popover: popover)
        func picker() throws -> NSPopUpButton? {
            presentation.prepareForTesting()
            let root = try XCTUnwrap(popover.contentViewController?.view)
            return descendant(of: root, identifier: "readerSettings.pageTurnStyle") as? NSPopUpButton
        }
        let popup = try XCTUnwrap(try picker(), "missing page turn style picker")
        XCTAssertEqual(popup.itemTitles, [PageTurnStyle.slide.displayName, PageTurnStyle.none.displayName])
        XCTAssertEqual(popup.titleOfSelectedItem, PageTurnStyle.slide.displayName, "a stored Flip reads as Slide")
        XCTAssertEqual(settings.pageTurnStyle, .flip, "opening the panel must not rewrite the stored value")
        popup.selectItem(at: 1)
        popup.sendAction(popup.action, to: popup.target)
        XCTAssertEqual(settings.pageTurnStyle, PageTurnStyle.none)
        settings.readerLayout = .scrolling
        XCTAssertTrue(try picker()?.isHidden ?? true, "scrolling has no page turns")
    }

    func testPageTurnSlidesOnlyWhenTheStyleAsksForIt() async throws {
        // Reduce Motion is injected: the result must not depend on the machine that runs the test.
        for (style, reduced, slides) in [(PageTurnStyle.slide, false, true), (.flip, false, true),
                                         (.none, false, false), (.slide, true, false)] {
            try await withReader(turnStyle: style, reducesMotion: reduced) { textView, indicator in
                let root = try XCTUnwrap(textView.window?.contentView)
                @MainActor func outgoing() -> NSView? { self.descendant(of: root, identifier: "reader.pageSlide.outgoing") }
                let first = try XCTUnwrap(indicator()).stringValue
                XCTAssertEqual(textView.onPageTap?(true), true)
                XCTAssertEqual(outgoing() != nil, slides, "style \(style.rawValue), reduced \(reduced)")
                try await Task.sleep(nanoseconds: 800_000_000)
                XCTAssertNil(outgoing(), "the transition must not stay over the text")
                XCTAssertNotEqual(try XCTUnwrap(indicator()).stringValue, first, "the page must advance")
            }
        }
    }

    private func descendant(of view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        let children = (view as? NSScrollView)?.documentView.map { [$0] } ?? view.subviews
        return children.lazy.compactMap { self.descendant(of: $0, identifier: identifier) }.first
    }

    private func withReader(
        showsNumbers: Bool = true, layout: ReaderLayout = .paginated, turnStyle: PageTurnStyle = .none,
        reducesMotion: Bool = false, columns: Int? = nil,
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
        settingsUnderTest = settings
        settings.readerLayout = layout
        settings.readerShowPageNumbers = showsNumbers
        if let columns { settings.readerColumns = columns }
        settings.pageTurnStyle = turnStyle
        let ready = expectation(description: "reader ready")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedRenderer: renderer, preparedChapterStore: chapterStore,
            preparedFulltextReader: { _ in payload }, preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in if name == "controls_usable" { ready.fulfill() } },
            reducesMotion: { reducesMotion })
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
            for child in view.subviews { if let found = find(in: child, where: matches) { return found } }
            return nil
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
