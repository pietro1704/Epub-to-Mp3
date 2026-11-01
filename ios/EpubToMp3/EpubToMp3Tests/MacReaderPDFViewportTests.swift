#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderPDFViewportTests: XCTestCase {
    func testPDFHasVisiblePagesAndTracksReaderViewport() async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "First page", body: "First readable passage."),
            (heading: "Second page", body: "Second readable passage.")
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        harness.controller.view.layoutSubtreeIfNeeded()
        let normalized = await harness.text.showPDF(source)
        XCTAssertEqual(normalized, false)
        let scroll = harness.composition.contentScrollView
        let pdf = try XCTUnwrap(scroll.documentView as? PDFView)
        XCTAssertEqual(pdf.document?.pageCount, 2)
        assertFillsViewport(pdf, in: scroll)
        pdf.layoutDocumentView()
        XCTAssertFalse(pdf.visiblePages.isEmpty, "A decoded document must have a visible page")
        for size in [NSSize(width: 620, height: 480), NSSize(width: 1000, height: 760)] {
            harness.controller.view.setFrameSize(size)
            harness.controller.view.layoutSubtreeIfNeeded()
            assertFillsViewport(pdf, in: scroll)
        }
        let second = try XCTUnwrap(pdf.document?.page(at: 1))
        pdf.go(to: second)
        XCTAssertTrue(pdf.currentPage === second)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(harness.player.isPlaying)
    }

    func testOpeningAnotherPDFReplacesTheDocumentAndKeepsItsViewport() async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        let first = try PdfFixture.createSinglePage(title: "First book")
        let second = try PdfFixture.createSinglePage(title: "Second book")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        harness.controller.view.layoutSubtreeIfNeeded()
        _ = await harness.text.showPDF(first)
        let old = try XCTUnwrap(harness.composition.contentScrollView.documentView as? PDFView)
        harness.document.currentBookId = "replacement-book"
        harness.document.loadGeneration = UUID()
        _ = await harness.text.showPDF(second)
        let scroll = harness.composition.contentScrollView
        let current = try XCTUnwrap(scroll.documentView as? PDFView)
        XCTAssertFalse(current === old)
        XCTAssertNil(old.superview)
        XCTAssertTrue(current.document?.page(at: 0)?.string?.contains("Second book") == true)
        assertFillsViewport(current, in: scroll)
    }

    func testCancelledOpenDoesNotInstallDocument() async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        let source = try PdfFixture.createSinglePage()
        defer { try? FileManager.default.removeItem(at: source) }
        harness.controller.view.layoutSubtreeIfNeeded()
        let load = Task { @MainActor in await harness.text.showPDF(source) }
        load.cancel()
        let result = await load.value
        XCTAssertNil(result)
        let pdf = try XCTUnwrap(harness.composition.contentScrollView.documentView as? PDFView)
        XCTAssertNil(pdf.document)
    }

    func testImportedPDFOpensInVisibleReaderWindow() async throws {
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let id = "pdf-opening-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let source = try PdfFixture.createSinglePage(title: "PDF opening acceptance",
                                                   bodyText: "This passage must be visible in the reader.")
        let original = try Data(contentsOf: source)
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: book.id)
            LocalFulltextCache.evict(bookId: book.id)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: root)
        }
        UserDefaults.standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let controller = MacReaderViewController(library: library,
            settings: AppSettings(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {})
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var surface: PDFView?
        for _ in 0..<200 {
            controller.view.layoutSubtreeIfNeeded()
            surface = descendants(controller.view).compactMap { $0 as? PDFView }.first
            if surface?.document?.pageCount == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pdf = try XCTUnwrap(surface)
        XCTAssertEqual(pdf.document?.pageCount, 1)
        pdf.layoutDocumentView()
        XCTAssertGreaterThan(pdf.visibleRect.width, 100)
        XCTAssertGreaterThan(pdf.visibleRect.height, 100)
        XCTAssertFalse(pdf.visiblePages.isEmpty)
        XCTAssertTrue(pdf.document?.page(at: 0)?.string?.contains("This passage must be visible") == true)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(window.isVisible)
    }

    private func assertFillsViewport(_ pdf: PDFView, in scroll: NSScrollView,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(scroll.contentSize.width, 100, file: file, line: line)
        XCTAssertGreaterThan(scroll.contentSize.height, 100, file: file, line: line)
        XCTAssertEqual(pdf.frame.width, scroll.contentSize.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(pdf.frame.height, scroll.contentSize.height, accuracy: 1, file: file, line: line)
    }
}
#endif
