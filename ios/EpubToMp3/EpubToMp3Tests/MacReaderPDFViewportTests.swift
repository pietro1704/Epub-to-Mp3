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
        let old = try XCTUnwrap(harness.composition.contentScrollView.documentView as? MacReaderPDFView)
        old.layoutDocumentView()
        let play = try playMenuItem(in: old, page: 0, text: "Lorem")
        var played: [PDFReadingAudioMap.Anchor] = []
        harness.text.onPlayPDF = { played.append($0) }
        harness.document.currentBookId = "replacement-book"
        harness.document.loadGeneration = UUID()
        _ = await harness.text.showPDF(second)
        let scroll = harness.composition.contentScrollView
        let current = try XCTUnwrap(scroll.documentView as? PDFView)
        XCTAssertFalse(current === old)
        XCTAssertNil(old.superview)
        XCTAssertTrue(current.document?.page(at: 0)?.string?.contains("Second book") == true)
        assertFillsViewport(current, in: scroll)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(play.action), to: play.target, from: play))
        XCTAssertTrue(played.isEmpty, "An action from the replaced PDF must not start audio for the new reader")
    }

    func testListeningToAPDFWithATextlessPageTellsOnceThatItWasSkipped() async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "", body: ""),
            (heading: "Second page", body: "Second readable passage.")
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = harness.controller
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        harness.controller.view.layoutSubtreeIfNeeded()
        _ = await harness.text.showPDF(source)
        let pdf = try XCTUnwrap(harness.composition.contentScrollView.documentView as? MacReaderPDFView)
        pdf.layoutDocumentView()
        pdf.go(to: try XCTUnwrap(pdf.document?.page(at: 1)))
        var played = 0
        harness.text.onPlayPDF = { _ in played += 1 }
        XCTAssertNil(window.attachedSheet, "Opening the book alone says nothing")

        let item = try playMenuItem(in: pdf, page: 1, text: "Second")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(played, 1, "The notice must not hold back playback")
        try await Task.sleep(nanoseconds: 500_000_000)
        let sheet = try XCTUnwrap(window.attachedSheet, "Listening must tell that a page was skipped")
        func labels(_ view: NSView) -> [String] {
            ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels)
        }
        let expected = L10n.string("convert.pdfPagesSkipped.one")
        XCTAssertTrue(labels(try XCTUnwrap(sheet.contentView)).contains(expected))
        window.endSheet(sheet)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(played, 2)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(window.attachedSheet, "The notice appears once per opened book")
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
        let source = try PdfFixture.createSinglePage(title: "PDF opening acceptance",
                                                     bodyText: "This passage must be visible in the reader.")
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try Data(contentsOf: source)
        try await withImportedPDF(source) { _, pdf, window, player in
            XCTAssertEqual(pdf.document?.pageCount, 1)
            XCTAssertGreaterThan(pdf.visibleRect.width, 100)
            XCTAssertGreaterThan(pdf.visibleRect.height, 100)
            XCTAssertFalse(pdf.visiblePages.isEmpty)
            XCTAssertTrue(pdf.document?.page(at: 0)?.string?.contains("This passage must be visible") == true)
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(try Data(contentsOf: source), original)
            XCTAssertTrue(window.isVisible)
        }
    }

    func testImportedPDFOpensOverCollidingWarmTextCache() async throws {
        let source = try PdfFixture.createSinglePage(title: "PDF wins over the text cache")
        defer { try? FileManager.default.removeItem(at: source) }
        try await withImportedPDF(source, prepareBook: { book in
            let payload = EbookFulltext(jobId: book.id, bookTitle: book.title, bookAuthor: nil,
                chapters: [.init(index: 1, name: "Wrong format", text: "A same-key EPUB cache must not hide the PDF.",
                    html: nil, css: nil, charCount: nil, segments: nil)])
            LocalFulltextCache.save(payload, bookId: book.id)
            XCTAssertNotNil(LocalFulltextCache.inMemoryPayload(bookId: book.id))
        }) { _, pdf, _, _ in
            XCTAssertTrue(pdf.document?.page(at: 0)?.string?.contains("PDF wins over the text cache") == true)
        }
    }

    func testTextPDFStartsFromClickedTextAndVisiblePageThroughNativeReaderActions() async throws {
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "First page", body: "Earlier text must not start when listening on another page."),
            (heading: "Second page", body: "The later passage is a selectable source of narration.")
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        var played: [PDFReadingAudioMap.Anchor] = []
        var genericListenRequests = 0
        try await withImportedPDF(source, onListen: { genericListenRequests += 1 },
            onPlayPDF: { played.append($0) }) { controller, pdf, _, _ in
            let second = try XCTUnwrap(pdf.document?.page(at: 1))
            pdf.go(to: second)
            pdf.layoutDocumentView()
            XCTAssertTrue(pdf.currentPage === second)

            let contextPlay = try playMenuItem(in: pdf, page: 1, text: "selectable", characterOffset: 4)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(contextPlay.action), to: contextPlay.target, from: contextPlay))
            let clicked = try XCTUnwrap(played.last)
            XCTAssertEqual(clicked.chapterIndex, 1)
            let chapterText = try XCTUnwrap(pdf.audioMap?.chapters[1].text)
            let word = try XCTUnwrap(chapterText.range(of: "selectable"))
            XCTAssertEqual(clicked.sourceScalarOffset, chapterText[..<word.lowerBound].unicodeScalars.count)

            let more = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "reader.more" })
            let listen = try XCTUnwrap(more.menu?.items.first { $0.representedObject as? String == ReaderTool.listen.rawValue })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(listen.action), to: listen.target, from: listen))
            XCTAssertEqual(played.count, 2)
            XCTAssertEqual(played.last?.chapterIndex, 1)
            XCTAssertEqual(genericListenRequests, 0, "PDF playback must use its own visible location")
        }
    }

    func testListeningFromATextlessCoverStartsAtTheNextPageWithText() async throws {
        let source = try PdfFixture.createMultiPage(pages: [
            (heading: "", body: ""),
            (heading: "Second page", body: "Second readable passage.")])
        defer { try? FileManager.default.removeItem(at: source) }
        var played: [PDFReadingAudioMap.Anchor] = []
        try await withImportedPDF(source, onPlayPDF: { played.append($0) }) { _, pdf, _, _ in
            pdf.go(to: try XCTUnwrap(pdf.document?.page(at: 0)))
            pdf.layoutDocumentView()
            XCTAssertTrue(pdf.currentPage === pdf.document?.page(at: 0))
            XCTAssertTrue(pdf.playFromVisiblePosition(), "A cover without text must not block listening")
            XCTAssertEqual(played.last, pdf.audioMap?.anchor(page: 1))
            XCTAssertNotNil(played.last)
        }
    }

    func testPDFWithoutSelectableTextDoesNotRequestPlayback() async throws {
        let source = try PdfFixture.createSinglePage(title: "", bodyText: "")
        defer { try? FileManager.default.removeItem(at: source) }
        try await withImportedPDF(source, onPlayPDF: { _ in XCTFail("Unmapped content cannot start audio") }) { _, pdf, _, _ in
            XCTAssertFalse(pdf.playFromVisiblePosition())
            XCTAssertNil(pdf.playbackMenu(at: NSPoint(x: pdf.bounds.midX, y: pdf.bounds.midY)))
        }
    }

    private func playMenuItem(in pdf: MacReaderPDFView, page index: Int, text: String,
                              characterOffset: Int = 0) throws -> NSMenuItem {
        let page = try XCTUnwrap(pdf.document?.page(at: index))
        let pageText = try XCTUnwrap(page.string) as NSString
        let range = pageText.range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound)
        guard range.location != NSNotFound else { throw CocoaError(.fileReadCorruptFile) }
        let bounds = page.characterBounds(at: range.location + characterOffset)
        let point = pdf.convert(NSPoint(x: bounds.midX, y: bounds.midY), from: page)
        return try XCTUnwrap(pdf.playbackMenu(at: point)?.items.first)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func withImportedPDF(
        _ source: URL,
        onListen: @escaping () -> Void = {},
        onPlayPDF: @escaping (PDFReadingAudioMap.Anchor) -> Void = { _ in },
        prepareBook: (BookEntity) -> Void = { _ in },
        body: (MacReaderViewController, MacReaderPDFView, NSWindow, AudioPlayer) throws -> Void
    ) async throws {
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let id = "pdf-opening-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let sourcePageCount = try XCTUnwrap(PDFDocument(url: source)).pageCount
        let library = LibraryStore(defaults: defaults, importDirectory: root)
        let book = try library.importBook(from: source)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard)
        defer {
            player.stop()
            for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) }
            ReaderProgressStore.evict(bookId: book.id)
            LocalFulltextCache.evict(bookId: book.id)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        prepareBook(book)
        UserDefaults.standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let controller = MacReaderViewController(library: library,
            settings: AppSettings(defaults: defaults), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            onListen: onListen, onPlayPDF: onPlayPDF)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        var surface: MacReaderPDFView?
        for _ in 0..<200 {
            controller.view.layoutSubtreeIfNeeded()
            surface = descendants(controller.view).compactMap { $0 as? MacReaderPDFView }.first
            if surface?.document?.pageCount == sourcePageCount { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pdf = try XCTUnwrap(surface)
        XCTAssertEqual(pdf.document?.pageCount, sourcePageCount)
        pdf.layoutDocumentView()
        try body(controller, pdf, window, player)
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
