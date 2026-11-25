#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// MAC-READER-MULTI-COLUMN: the Mac-only Columns control must change the page.
/// Observes only what is drawn, so it holds for any column implementation.
@MainActor
final class MacReaderColumnsTests: XCTestCase {
    func testPaginatedPageShowsOneColumnByDefault() async throws {
        let columns = try await visibleColumnOrigins(columns: 1)
        XCTAssertEqual(columns.count, 1, "origins: \(columns)")
    }

    func testPaginatedPageShowsTwoSideBySideColumns() async throws {
        let columns = try await visibleColumnOrigins(columns: 2)
        XCTAssertEqual(columns.count, 2, "origins: \(columns)")
    }

    func testScrollingPageShowsTwoSideBySideColumns() async throws {
        let columns = try await visibleColumnOrigins(columns: 2, layout: .scrolling)
        XCTAssertEqual(columns.count, 2, "origins: \(columns)")
    }

    /// Left edges of the text lines drawn on the first page of a wide window.
    private func visibleColumnOrigins(columns: Int, layout: ReaderLayout = .paginated) async throws -> [Int] {
        let identifier = "reader-columns-\(UUID().uuidString)"
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
        let book = BookEntity(id: identifier, title: "Synthetic columns", bookmark: Data([1]),
                              displayFilename: "columns.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let text = String(repeating: "A synthetic sentence that fills the reading column with words. ", count: 600)
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Columns", text: text, html: nil, css: nil, charCount: text.count, segments: nil),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: directory))
        let chapterStore = PreparedReaderChapterStore(directory: directory.appendingPathComponent("chapters"))
        defer { try? FileManager.default.removeItem(at: directory) }
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = layout
        settings.readerColumns = columns
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
        let textView = try XCTUnwrap(findText(in: controller.view))
        let manager = try XCTUnwrap(textView.layoutManager)
        manager.textContainers.forEach { manager.ensureLayout(for: $0) }
        var origins = Set<Int>()
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) {
            _, used, container, _, _ in
            guard let host = container.textView else { return }
            let rect = used.offsetBy(dx: host.textContainerOrigin.x, dy: host.textContainerOrigin.y)
            let drawn = host.convert(rect, to: controller.view)
            let page = host.enclosingScrollView.map { $0.convert($0.bounds, to: controller.view) } ?? controller.view.bounds
            if page.contains(NSPoint(x: drawn.minX + 1, y: drawn.midY)) { origins.insert(Int(drawn.minX.rounded())) }
        }
        let shot = controller.view
        if let bitmap = shot.bitmapImageRepForCachingDisplay(in: shot.bounds) {
            shot.cacheDisplay(in: shot.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "mac-reader-columns-\(columns)-\(layout.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        return origins.sorted()
    }
}
#endif
