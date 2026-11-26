#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// PARITY-MAC-READER-5: the Mac contents list offers the iPhone's chapter audio controls: a download
/// button per chapter and the download all, cancel and remove actions.
@MainActor
final class MacReaderContentsAudioTests: XCTestCase {
    func testContentsOffersTheiPhoneChapterAudioControls() async throws {
        let suite = "mac-contents-audio-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let source = try EpubFixture.createWithChapters(["First synthetic chapter.", "Second synthetic chapter."])
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
        window.makeKeyAndOrderFront(nil)
        controller.setBook(book.id)
        let textView = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first)
        for _ in 0..<50 where textView.string.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let more = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityIdentifier() == "reader.more" }?.menu)
        let contents = try XCTUnwrap(more.items.first { $0.representedObject as? String == ReaderTool.contents.rawValue })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(contents.action), to: contents.target, from: contents))
        try await Task.sleep(nanoseconds: 500_000_000)

        let list = try XCTUnwrap(NSApp.windows.lazy.compactMap { candidate in
            candidate.contentView.flatMap { content in
                self.descendants(content).compactMap { $0 as? NSTableView }
                    .first { $0.delegate is MacReaderContentsPresentation }
            }
        }.first)
        list.layoutSubtreeIfNeeded()
        for row in 0..<list.numberOfRows { _ = list.view(atColumn: 0, row: row, makeIfNecessary: true) }
        let popover = try XCTUnwrap(list.window?.contentView)
        let present = Set(descendants(popover).map { $0.accessibilityIdentifier() })
        let expected = ["reader.toc.actions", "reader.toc.download.0", "reader.toc.download.1"]
        XCTAssertEqual(expected.filter { !present.contains($0) }, [], "missing contents audio controls")
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
