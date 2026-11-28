#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// The loading cover has the pixel size of the artwork. That size must never decide how tall the window is:
/// the overlay keeps its constraints while hidden, so a large cover would hold the window open for good.
@MainActor
final class MacReaderWindowHeightTests: XCTestCase {
    func testALargeCoverDoesNotResizeTheReaderWindow() async throws {
        let identifier = "reader-window-height-\(UUID().uuidString)"
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
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let cover = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let book = BookEntity(id: identifier, title: "Synthetic tall cover", bookmark: Data([1]),
                              displayFilename: "cover.epub", addedAt: Date(), coverPNG: cover)
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let text = (1...200).map { "Synthetic sentence number \($0) fills the page." }.joined(separator: " ")
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Cover", text: text, html: nil, css: nil, charCount: text.count, segments: nil),
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: directory))
        let chapterStore = PreparedReaderChapterStore(directory: directory.appendingPathComponent("chapters"))
        defer { try? FileManager.default.removeItem(at: directory) }
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let ready = expectation(description: "reader ready")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            settings: AppSettings(defaults: defaults),
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedRenderer: renderer, preparedChapterStore: chapterStore,
            preparedFulltextReader: { _ in payload }, preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in if name == "controls_usable" { ready.fulfill() } })
        let size = NSSize(width: 1000, height: 600)
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

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, 600, accuracy: 1,
                       "opening a book must not resize the window")
    }
}
#endif
