#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// Mouse behaviour driven through AppKit's own dispatch: a right click resolves its menu through the
/// view hierarchy, and a press goes through the text view's tracking loop with queued events.
/// Calling the app's callbacks directly would not reproduce any of these reports.
@MainActor
final class MacMouseInteractionTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                       after delay: TimeInterval = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + delay, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// Press, optional drag, release. The release is queued first so a tracking loop can consume it;
    /// when the view does not track, it is delivered to the view like AppKit would.
    private func press(_ view: NSView, from start: NSPoint, to end: NSPoint, in window: NSWindow,
                       holding: TimeInterval = 0) throws {
        if start != end {
            let middle = NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            for point in [middle, end] { NSApp.postEvent(try mouse(.leftMouseDragged, at: point, in: window), atStart: false) }
        }
        NSApp.postEvent(try mouse(.leftMouseUp, at: end, in: window, after: holding), atStart: false)
        view.mouseDown(with: try mouse(.leftMouseDown, at: start, in: window))
        while let pending = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                            until: .distantPast, inMode: .default, dequeue: true) {
            if pending.type == .leftMouseUp { view.mouseUp(with: pending) } else { view.mouseDragged(with: pending) }
        }
    }

    /// Imports a synthetic EPUB into an isolated library; reading anchors are restored afterwards.
    private func importSyntheticBook(body: String) throws -> (LibraryStore, BookEntity, UserDefaults) {
        let suite = "mac-mouse-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let source = try EpubFixture.createWithChapter(body: body)
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: book.id)
            LocalFulltextCache.evict(bookId: book.id)
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        return (library, book, defaults)
    }

    private func show(_ controller: NSViewController, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        return window
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil); window.contentViewController = nil; window.close()
    }

    func testRightClickOnALibraryBookOpensItsOptions() async throws {
        let (library, book, defaults) = try importSyntheticBook(body: "Synthetic text.")
        let controller = MacLibraryViewController(library: library,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in })
        let window = show(controller, width: 900, height: 650)
        defer { close(window) }
        let openID = "library.book.open.\(book.id)"
        var button: NSView?
        for _ in 0..<50 where button == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            window.layoutIfNeeded()
            button = descendants(controller.view).first { $0.accessibilityIdentifier() == openID }
        }
        let cover = try XCTUnwrap(button, "the book card is on screen")
        let point = cover.convert(NSPoint(x: cover.bounds.midX, y: cover.bounds.midY), to: nil)
        let event = try mouse(.rightMouseDown, at: point, in: window)

        let content = try XCTUnwrap(window.contentView)
        var target = content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        var menu: NSMenu?
        while menu == nil, let view = target {
            menu = view.menu(for: event)
            target = view.superview
        }
        let titles = menu?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains(L10n.string("library.removeFromLibrary")), "right click shows the book options: \(titles)")
        XCTAssertTrue(titles.contains(L10n.string("language.chooseTitle")), "right click shows the book options: \(titles)")
    }

    private func openReader() async throws -> (MacReaderViewController, NSWindow, MacReaderTextView) {
        let (library, book, defaults) = try importSyntheticBook(
            body: String(repeating: "Synthetic words for mouse selection. ", count: 200))
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
                                 location: .standard)
        addTeardownBlock { @MainActor in player.stop() }
        let controller = MacReaderViewController(library: library, settings: AppSettings(defaults: defaults),
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {})
        let window = show(controller, width: 700, height: 600)
        controller.setBook(book.id)
        let textView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first)
        for _ in 0..<60 where !textView.string.contains("Synthetic words") {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        window.layoutIfNeeded()
        return (controller, window, textView)
    }

    func testARealClickInThePageCentreTogglesTheChromeOnce() async throws {
        let (_, window, textView) = try await openReader()
        defer { close(window) }
        var toggles = 0
        textView.onToggleChrome = { toggles += 1 }
        let visible = textView.visibleRect
        let centre = textView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)

        try press(textView, from: centre, to: centre, in: window)
        XCTAssertEqual(toggles, 1, "one click toggles the player bar once")
        try press(textView, from: centre, to: centre, in: window)
        XCTAssertEqual(toggles, 2, "the next click toggles it back")
    }

    func testDraggingOverWordsOffersTheSelectionActions() async throws {
        let (_, window, textView) = try await openReader()
        defer { close(window) }
        var offered: [NSRange] = []
        // Returning no items keeps the test free of a modal menu loop.
        textView.onBuildSelectionMenu = { offered.append($0); return [] }
        var toggles = 0
        textView.onToggleChrome = { toggles += 1 }
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let start = (textView.string as NSString).range(of: "words for mouse")
        XCTAssertNotEqual(start.location, NSNotFound)
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: start,
            actualCharacterRange: nil), in: container)
        let origin = textView.textContainerOrigin
        let from = textView.convert(NSPoint(x: rect.minX + origin.x + 1, y: rect.minY + origin.y + 4), to: nil)
        let to = textView.convert(NSPoint(x: rect.maxX + origin.x - 1, y: rect.maxY + origin.y - 4), to: nil)

        try press(textView, from: from, to: to, in: window)

        XCTAssertGreaterThan(textView.selectedRange().length, 0, "the drag selects text")
        XCTAssertEqual(offered, [textView.selectedRange()], "releasing the drag offers the actions for the selection")
        XCTAssertEqual(toggles, 0, "selecting text is not a chrome click")
    }

    func testHoldingTheButtonOnAWordSelectsItAndOffersTheActions() async throws {
        let (_, window, textView) = try await openReader()
        defer { close(window) }
        var offered: [String] = []
        textView.onBuildSelectionMenu = { [weak textView] range in
            offered.append((textView?.string as NSString?)?.substring(with: range) ?? "")
            return []
        }
        var toggles = 0
        textView.onToggleChrome = { toggles += 1 }
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let word = (textView.string as NSString).range(of: "selection")
        XCTAssertNotEqual(word.location, NSNotFound)
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: word,
            actualCharacterRange: nil), in: container)
        let origin = textView.textContainerOrigin
        let point = textView.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), to: nil)

        try press(textView, from: point, to: point, in: window, holding: 0.8)

        XCTAssertEqual(offered, ["selection"], "holding on a word selects it and offers its actions")
        XCTAssertEqual(toggles, 0, "a hold is not a chrome click")
    }

    func testTheOnlineVoiceRowOffersNoSampleItCannotPlay() async throws {
        let name = "mac-edge-sample-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.allowOnlineAudioFallback = true
        let model = ModelsByLanguageModel(source: ModelsByLanguageModelTests.FakeSource(), settings: settings,
            terms: SpeechModelTermsAcceptanceStore(defaults: defaults), systemVoiceLanguages: { [] })
        await model.load()
        let controller = MacModelsViewController(sharing: model, onlyLanguage: "pt")
        let window = show(controller, width: 900, height: 700)
        defer { close(window) }
        var menu: NSView?
        for _ in 0..<60 where menu == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            window.layoutIfNeeded()
            if let table = descendants(controller.view).compactMap({ $0 as? NSTableView }).first {
                menu = (0..<table.numberOfRows).lazy
                    .compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) }
                    .flatMap { self.descendants($0) }
                    .first { $0.accessibilityIdentifier() == "models.menu.pt.edge:pt" }
            }
        }
        // The audition renderer accepts only an installed Piper voice, so a sample entry here can only fail.
        XCTAssertEqual(try XCTUnwrap(menu, "the Edge row is listed").isHidden, true)
    }
}
#endif
