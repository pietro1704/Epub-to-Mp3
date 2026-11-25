#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// MAC-READER-TOOLBAR-VISIBLE: on macOS the reader's "Aa" and the other header
/// buttons stay visible all the time; a click in the middle of the page must
/// not hide them.
@MainActor
final class MacReaderToolbarVisibilityTests: XCTestCase {
    func testCentreClickKeepsReaderToolbarVisible() async throws {
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
        let controller = MacReaderViewController(library: library, settings: AppSettings(defaults: defaults),
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            onClose: {})
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
        for click in [textView.onToggleChrome, surface.onToggleChrome, textView.onToggleChrome] {
            click?()
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(header.isHidden, "A page click must not hide the reader header")
            for button in buttons {
                XCTAssertFalse(button.isHiddenOrHasHiddenAncestor,
                               "\(button.title.isEmpty ? String(describing: button.image) : button.title) must stay visible")
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
