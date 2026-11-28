#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// Escape dismisses what is on top: an open reader popover first, and only then the book.
@MainActor
final class MacReaderEscapeTests: XCTestCase {
    func testEscapeClosesTheAppearancePopoverBeforeTheBook() async throws {
        let identifier = "reader-escape-\(UUID().uuidString)"
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
        let book = BookEntity(id: identifier, title: "Synthetic escape", bookmark: Data([1]),
                              displayFilename: "escape.epub", addedAt: Date(), coverPNG: nil)
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let text = (1...200).map { "Synthetic sentence number \($0) fills the page." }.joined(separator: " ")
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "One", text: text, html: nil, css: nil, charCount: text.count, segments: nil),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: directory))
        let chapterStore = PreparedReaderChapterStore(directory: directory.appendingPathComponent("chapters"))
        defer { try? FileManager.default.removeItem(at: directory) }
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        var closed = 0
        let ready = expectation(description: "reader ready")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            settings: AppSettings(defaults: defaults),
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: { closed += 1 },
            preparedRenderer: renderer, preparedChapterStore: chapterStore,
            preparedFulltextReader: { _ in payload }, preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in if name == "controls_usable" { ready.fulfill() } })
        let size = NSSize(width: 1000, height: 700)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.layoutIfNeeded()
        await fulfillment(of: [ready], timeout: 5)
        window.layoutIfNeeded()

        let appearance = try XCTUnwrap(button(ReaderTool.appearance.accessibilityIdentifier, in: controller.view))
        appearance.performClick(nil)
        try await waitUntil { self.popoverWindows(of: window).count == 1 }
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))

        controller.view.keyDown(with: escape)

        XCTAssertEqual(closed, 0, "the first Escape must keep the book open")
        try await waitUntil { self.popoverWindows(of: window).isEmpty }

        controller.view.keyDown(with: escape)

        XCTAssertEqual(closed, 1, "with no popover, Escape closes the book")
    }

    private func button(_ identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        return view.subviews.lazy.compactMap { self.button(identifier, in: $0) }.first
    }

    private func popoverWindows(of window: NSWindow) -> [NSWindow] {
        (window.childWindows ?? []).filter(\.isVisible)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(condition(), "timed out")
    }
}
#endif
