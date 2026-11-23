#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// The Mac reader shows rendered HTML, whose offsets differ from the parser
/// text. A search match must select the query in the text the view shows.
@MainActor
final class MacReaderSearchTests: XCTestCase {
    func testSearchSelectsTheMatchInTheRenderedCurrentChapter() async throws {
        let reader = try await openReader()
        defer { reader.close() }
        reader.controller.annotations.performSearch(query: "needle")
        XCTAssertEqual(reader.selectedText(), "needle")
    }

    func testSearchMovesToTheMatchingChapterAndSelectsTheRenderedMatch() async throws {
        let reader = try await openReader()
        defer { reader.close() }
        reader.controller.annotations.performSearch(query: "haystack")
        XCTAssertEqual(reader.selectedText(), "haystack")
        XCTAssertTrue(reader.text.string.contains("Second chapter preface"))
    }

    private struct OpenReader {
        let controller: MacReaderViewController
        let text: MacReaderTextView
        let close: () -> Void

        func selectedText() -> String {
            (text.string as NSString).substring(with: text.selectedRange())
        }
    }

    private func openReader() async throws -> OpenReader {
        let identifier = "mac-search-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey, "readerProgress.v1", "readerWarmBookIDs.v1",
                    "reader.recentTool.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        let book = BookEntity(id: identifier, title: "Search", bookmark: Data([1]),
                              displayFilename: "search.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        // Each parser text starts at the match while the rendered HTML has a
        // preface before it, so parser offsets select the wrong characters.
        let firstText = "The needle is here."
        let secondText = "A haystack waits."
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "First", text: firstText,
                  html: "<p>First chapter preface words come before it.</p><p>The needle is here.</p>",
                  css: nil, charCount: firstText.count, segments: nil),
            .init(index: 2, name: "Second", text: secondText,
                  html: "<p>Second chapter preface words come before it.</p><p>A haystack waits.</p>",
                  css: nil, charCount: secondText.count, segments: nil),
        ])
        let preparedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: preparedDirectory))
        let chapterStore = PreparedReaderChapterStore(directory: preparedDirectory.appendingPathComponent("chapters"))
        ReaderProgressStore.save(bookId: identifier, chapterIndex: 0, offsetFraction: 0)
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .scrolling
        let controlsReady = expectation(description: "The initial reader restoration must finish before searching.")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedRenderer: renderer, preparedChapterStore: chapterStore,
            preparedFulltextReader: { _ in payload }, preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in
                if name == "controls_usable" { controlsReady.fulfill() }
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        let close = {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: preparedDirectory)
        }
        await fulfillment(of: [controlsReady], timeout: 5)
        func findText(in view: NSView) -> MacReaderTextView? {
            if let text = view as? MacReaderTextView { return text }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        guard let text = findText(in: controller.view) else {
            close()
            struct MissingTextView: Error {}
            XCTFail("The Mac reader text view was not found")
            throw MissingTextView()
        }
        XCTAssertTrue(text.string.contains("First chapter preface"), "The first chapter must render its HTML")
        return OpenReader(controller: controller, text: text, close: close)
    }
}
#endif
