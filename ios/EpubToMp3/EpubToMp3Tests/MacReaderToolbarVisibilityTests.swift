#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// MAC-UNSYNCED-HEADER-MINIPLAYER: as on the iPhone, one click on the page hides
/// the reader header and the mini player together, and the next one shows both.
/// This replaces the earlier MAC-READER-TOOLBAR-VISIBLE rule.
@MainActor
final class MacReaderToolbarVisibilityTests: XCTestCase {
    func testOnePageClickHidesAndShowsTheHeaderTogetherWithTheMiniPlayer() async throws {
        let suite = "mac-reader-toolbar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let source = try EpubFixture.createWithChapter(body: String(repeating: "Toolbar stays visible. ", count: 200))
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
                                 location: .standard)
        // What the window is told about the mini player after each click.
        var miniPlayerHidden: [Bool] = []
        let controller = MacReaderViewController(library: library, settings: AppSettings(defaults: defaults),
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onClose: {}, onChromeChanged: { miniPlayerHidden.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: book.id)
            LocalFulltextCache.evict(bookId: book.id)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 900, height: 650))
        controller.setBook(book.id)
        let textView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first)
        for _ in 0..<50 where textView.string.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        controller.view.layoutSubtreeIfNeeded()
        let header = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSVisualEffectView }
            .first { $0.material == .headerView })
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertFalse(header.isHidden)
        XCTAssertFalse(buttons.isEmpty)

        let surface = try XCTUnwrap(controller.view as? MacReaderSurfaceView)
        let textFrame = textView.convert(textView.bounds, to: controller.view)
        let clicks = [textView.onToggleChrome, surface.onToggleChrome, textView.onToggleChrome, surface.onToggleChrome]
        for (index, click) in clicks.enumerated() {
            let hidden = index.isMultiple(of: 2)
            click?()
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(miniPlayerHidden.count, index + 1)
            XCTAssertEqual(miniPlayerHidden.last, hidden, "click \(index + 1): mini player")
            XCTAssertEqual(header.isHidden, hidden, "click \(index + 1): header")
            for button in buttons {
                XCTAssertEqual(button.isHiddenOrHasHiddenAncestor, hidden,
                               "click \(index + 1): \(button.title.isEmpty ? String(describing: button.image) : button.title)")
            }
            XCTAssertEqual(textView.convert(textView.bounds, to: controller.view), textFrame,
                           "hiding the chrome must not move the page")
        }
        // MAC-READER-TOOLBAR-TITLE-AMBIGUOUS: one possible title position, centred between the controls.
        let title = try XCTUnwrap(descendants(controller.view)
            .first { $0.accessibilityIdentifier() == "reader.title" })
        let toolbar = try XCTUnwrap(title.superview as? NSStackView)
        let index = try XCTUnwrap(toolbar.arrangedSubviews.firstIndex(of: title))
        let before = toolbar.arrangedSubviews[index - 1], after = toolbar.arrangedSubviews[index + 1]
        XCTAssertEqual(before.frame.width, after.frame.width, accuracy: 1, "the title must not drift to a side")
        for view in [before, title, after] {
            XCTAssertFalse(view.hasAmbiguousLayout, "ambiguous reader header layout")
        }
        attachCapture(of: controller.view, name: "mac-reader-toolbar-after-page-click")
    }

    /// MAC-CHROME-HIDE-REPAGINATES: the window, not only the reader, keeps the
    /// text viewport when the chrome toggles (CONTEXT.md, chrome-stable viewport).
    func testHidingTheChromeKeepsTheWindowTextViewport() async throws {
        let suite = "mac-chrome-viewport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let source = try EpubFixture.createWithChapter(body: String(repeating: "Stable viewport. ", count: 400))
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
                                 location: .standard)
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .sepia
        let controller = MacAppKitRootController(settings: settings, library: library,
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil); window.contentViewController = nil; window.close()
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: book.id)
            LocalFulltextCache.evict(bookId: book.id)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1000, height: 700))
        controller.showReader(bookID: book.id)
        let textView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first)
        for _ in 0..<50 where textView.string.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        func miniPlayerButtons() -> [NSButton] {
            descendants(controller.view).compactMap { $0 as? NSButton }
                .filter { $0.toolTip == L10n.string("player.play") && !$0.isHiddenOrHasHiddenAncestor }
        }
        XCTAssertFalse(miniPlayerButtons().isEmpty, "the mini player starts visible")
        let viewport = scroll.convert(scroll.bounds, to: controller.view)
        for (index, hidden) in [true, false, true].enumerated() {
            textView.onToggleChrome?()
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(miniPlayerButtons().isEmpty, hidden, "click \(index + 1): mini player")
            XCTAssertEqual(scroll.convert(scroll.bounds, to: controller.view), viewport,
                           "click \(index + 1): the text viewport must not change")
            guard hidden else { continue }
            // The strip left by the hidden mini player is part of the page.
            let surface = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderSurfaceView }.first)
            let strip = try XCTUnwrap(surface.superview)
            XCTAssertEqual(strip.layer?.backgroundColor, surface.layer?.backgroundColor,
                           "click \(index + 1): the empty strip must use the reader background")
        }
    }

    /// Evidence for review: the reader after the page clicks, header still shown.
    private func attachCapture(of view: NSView, name: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
