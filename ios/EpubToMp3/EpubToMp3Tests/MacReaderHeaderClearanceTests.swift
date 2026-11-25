#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// The reader header is drawn above the page, so the text viewport must start below it:
/// otherwise the chapter opening is hidden and every page turn skips the covered lines.
@MainActor
final class MacReaderHeaderClearanceTests: XCTestCase {
    func testTheHeaderCoversNoTextAtTheChapterStartOrAcrossAPageTurn() async throws {
        let identifier = "reader-header-\(UUID().uuidString)"
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
        let book = BookEntity(id: identifier, title: "Synthetic header", bookmark: Data([1]),
                              displayFilename: "header.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let text = (1...600).map { "Synthetic sentence number \($0) fills the page." }.joined(separator: " ")
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Header", text: text, html: nil, css: nil, charCount: text.count, segments: nil),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: directory))
        let chapterStore = PreparedReaderChapterStore(directory: directory.appendingPathComponent("chapters"))
        defer { try? FileManager.default.removeItem(at: directory) }
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let ready = expectation(description: "reader ready")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedRenderer: renderer, preparedChapterStore: chapterStore,
            preparedFulltextReader: { _ in payload }, preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in if name == "controls_usable" { ready.fulfill() } })
        let size = NSSize(width: 1000, height: 700)
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

        let textView = try XCTUnwrap(descendant(of: controller.view) { $0 as? MacReaderTextView })
        let header = try XCTUnwrap(descendant(of: controller.view) { view -> NSVisualEffectView? in
            guard let effect = view as? NSVisualEffectView, effect.material == .headerView else { return nil }
            return effect
        })
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        let manager = try XCTUnwrap(textView.layoutManager)
        manager.textContainers.forEach { manager.ensureLayout(for: $0) }

        /// Characters of the lines a reader can see: inside the page viewport and not under the header.
        func readableCharacters() -> NSRange {
            let page = scroll.convert(scroll.bounds, to: controller.view)
            let covered = header.convert(header.bounds, to: controller.view)
            var characters: NSRange?
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
                _, used, _, glyphs, _ in
                let rect = used.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                let drawn = textView.convert(rect, to: controller.view)
                let middle = NSPoint(x: drawn.minX + 1, y: drawn.midY)
                guard page.contains(middle), !covered.contains(middle) else { return }
                let line = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                characters = characters.map { NSUnionRange($0, line) } ?? line
            }
            return characters ?? NSRange(location: NSNotFound, length: 0)
        }

        let overlap = scroll.convert(scroll.bounds, to: controller.view)
            .intersection(header.convert(header.bounds, to: controller.view))
        XCTAssertEqual(overlap.isNull ? 0 : overlap.height, 0, accuracy: 1, "the header must not cover the page")
        let first = readableCharacters()
        XCTAssertEqual(first.location, 0, "the chapter opening must be readable")

        XCTAssertEqual(textView.onPageTap?(true), true)
        try await Task.sleep(nanoseconds: 300_000_000)
        let second = readableCharacters()
        XCTAssertGreaterThan(second.location, first.location, "the page turned")
        XCTAssertLessThanOrEqual(second.location, NSMaxRange(first), "a page turn must not skip any line")
    }

    private func descendant<T: NSView>(of view: NSView, matching: (NSView) -> T?) -> T? {
        if let match = matching(view) { return match }
        for subview in view.subviews {
            if let match = descendant(of: subview, matching: matching) { return match }
        }
        return nil
    }
}
#endif
