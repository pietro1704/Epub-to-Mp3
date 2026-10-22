#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderChapterNavigationTests: XCTestCase {
    func testActualLOTRBackwardChapterBoundaryKeepsLastGlyphVisible() async throws {
        guard ProcessInfo.processInfo.environment["EPUBTOMP3_RUN_SEEDED_LOTR_JOURNEY"] == "1" else {
            throw XCTSkip("Seeded LOTR journey requires explicit opt-in; deterministic boundary tests run separately.")
        }
        let bookID = try XCTUnwrap(ProcessInfo.processInfo.environment["EPUBTOMP3_SEEDED_LOTR_BOOK_ID"], "Provide the explicitly seeded LOTR book identity.")
        let standard = UserDefaults.standard
        let group = try XCTUnwrap(UserDefaults(suiteName: LibraryStore.appGroupID))
        let library = LibraryStore(defaults: group)
        let book = try XCTUnwrap(library.books.first { $0.id == bookID })
        let fulltext = try XCTUnwrap(LocalFulltextCache.read(bookId: bookID))
        let currentIndex = try XCTUnwrap(fulltext.chapters.indices.dropFirst().max {
            fulltext.chapters[$0 - 1].text.count < fulltext.chapters[$1 - 1].text.count
        })
        let previousIndex = currentIndex - 1
        let previousChapter = fulltext.chapters[previousIndex]
        let currentChapter = fulltext.chapters[currentIndex]
        let previousTextLength = previousChapter.text.count
        XCTAssertGreaterThan(previousTextLength, 10_000, "Use an actual long LOTR chapter at the boundary.")
        let geometryFulltext = EbookFulltext(jobId: fulltext.jobId, bookTitle: fulltext.bookTitle,
                                             bookAuthor: fulltext.bookAuthor,
                                             chapters: fulltext.chapters.indices.map { index in
            let chapter = fulltext.chapters[index]
            guard index == previousIndex || index == currentIndex else { return chapter }
            return EbookFulltext.Chapter(
                index: chapter.index, name: chapter.name, sourcePath: chapter.sourcePath,
                text: chapter.text, speechText: chapter.speechText, html: nil, css: nil,
                charCount: chapter.charCount, segments: chapter.segments,
                resources: chapter.resources, footnotes: chapter.footnotes,
                contentKind: chapter.contentKind
            )
        })

        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey,
                    "readerWarmBookIDs.v1",
                    "readerProgress.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        LocalFulltextCache.evictInMemoryPayload(bookId: bookID)
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { standard.set(value, forKey: key) }
                else { standard.removeObject(forKey: key) }
            }
            _ = LocalFulltextCache.read(bookId: bookID)
        }
        ReaderProgressStore.save(bookId: bookID, chapterIndex: currentIndex,
                                 offsetFraction: 0, defaults: standard)
        standard.set(bookID, forKey: ReaderSessionState.currentlyReadingBookIDKey)

        let settingsSuite = "lotr-boundary-\(UUID().uuidString)"
        let settingsDefaults = try XCTUnwrap(UserDefaults(suiteName: settingsSuite))
        let settings = AppSettings(defaults: settingsDefaults)
        settings.readerLayout = .paginated
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: settingsDefaults)))
        let preparedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("lotr-boundary-\(UUID().uuidString)", isDirectory: true)
        let preparedStore = PreparedReaderChapterStore(directory: preparedRoot)
        let controlsReady = expectation(description: "The actual LOTR chapter and controls must finish loading.")
        controlsReady.assertForOverFulfill = false
        let preparedRenderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: preparedRoot))
        let controller = MacReaderViewController(
            library: library,
            settings: settings,
            player: player,
            bookmarkStore: BookmarkStore(defaults: settingsDefaults, storageKey: "bookmarks"),
            onClose: {},
            preparedRenderer: preparedRenderer,
            preparedChapterStore: preparedStore,
            preparedFulltextReader: { _ in geometryFulltext },
            preparedFulltextWriter: { _, _ in },
            openStageObserver: { name, _ in
                if name == "controls_usable" { controlsReady.fulfill() }
            }
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            player.stop()
            try? FileManager.default.removeItem(at: preparedRoot)
            settingsDefaults.removePersistentDomain(forName: settingsSuite)
        }
        window.layoutIfNeeded()
        await fulfillment(of: [controlsReady], timeout: 30)

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let text = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? MacReaderTextView }.first)
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        window.layoutIfNeeded()
        XCTAssertEqual(text.string.isEmpty, false, "The reader must show the imported LOTR chapter.")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        let geometryText = text
        let geometryScroll = scroll
        XCTAssertEqual(geometryText.string.isEmpty, false)
        XCTAssertEqual(geometryScroll.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertEqual(geometryText.onPageTap?(false), true,
                       "Move backward from the start into the previous real chapter.")
        for _ in 0..<100 where ReaderProgressStore.read(bookId: bookID, defaults: standard)?.chapterIndex != previousIndex {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(geometryText.string, previousChapter.text)
        window.layoutIfNeeded()
        let container = try XCTUnwrap(geometryText.textContainer)
        let layoutManager = try XCTUnwrap(geometryText.layoutManager)
        layoutManager.ensureLayout(for: container)
        let usedRect = layoutManager.usedRect(for: container)
        let visibleRect = geometryScroll.contentView.documentVisibleRect
        XCTAssertGreaterThan(usedRect.height, geometryScroll.contentView.bounds.height,
                             "The previous real chapter must exercise a multi-viewport boundary.")
        XCTAssertLessThanOrEqual(usedRect.maxY, visibleRect.maxY + 0.5,
                                 "The final real-book glyph must fit in the visible document rect.")
        XCTAssertLessThanOrEqual(visibleRect.maxY - usedRect.maxY,
                                 geometryText.textContainerInset.height + 0.5,
                                 "The real chapter must not end with an unexplained blank tail.")
        let backwardProgress = try XCTUnwrap(ReaderProgressStore.read(bookId: bookID, defaults: standard))
        XCTAssertEqual(backwardProgress.chapterIndex, previousIndex)
        XCTAssertEqual(backwardProgress.offsetFraction, 1, accuracy: 0.001)

        XCTAssertEqual(geometryText.onPageTap?(true), true, "Return forward across the real chapter boundary.")
        XCTAssertEqual(geometryText.string, currentChapter.text)
        let forwardProgress = try XCTUnwrap(ReaderProgressStore.read(bookId: bookID, defaults: standard))
        XCTAssertEqual(forwardProgress.chapterIndex, currentIndex)
        XCTAssertEqual(forwardProgress.offsetFraction, 0, accuracy: 0.001)
        XCTAssertEqual(book.id, bookID)
    }

    func testBackwardFromChapterStartLandsAtPreviousChapterEnd() async throws {
        try await verifyChapterBoundary(openTableOfContents: false)
    }

    func testBackwardChapterCrossingAfterOpeningTableOfContents() async throws {
        try await verifyChapterBoundary(openTableOfContents: true)
    }

    private func verifyChapterBoundary(openTableOfContents: Bool) async throws {
        let identifier = "chapter-crossing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey, "readerProgress.v1", "readerWarmBookIDs.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: identifier)
        }
        let book = BookEntity(id: identifier, title: "Chapter crossing", bookmark: Data([1]),
                              displayFilename: "crossing.epub", addedAt: Date())
        defaults.set(try JSONEncoder().encode([book]), forKey: "library")
        let longText = String(repeating: "A complete line of previous chapter text.\n", count: 200)
        let currentText = String(repeating: "A complete line of current chapter text.\n", count: 240)
        let payload = EbookFulltext(jobId: identifier, bookTitle: nil, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Previous", text: longText, html: nil, css: nil,
                  charCount: longText.count, segments: nil),
            .init(index: 2, name: "Current", text: currentText, html: nil, css: nil,
                  charCount: currentText.count, segments: nil),
        ])
        let preparedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: preparedDirectory))
        let chapterStore = PreparedReaderChapterStore(directory: preparedDirectory.appendingPathComponent("chapters"))
        defer { try? FileManager.default.removeItem(at: preparedDirectory) }
        ReaderProgressStore.save(bookId: identifier, chapterIndex: 1, offsetFraction: 0)
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let controlsReady = expectation(description: "The initial reader restoration must finish before navigating.")
        let controller = MacReaderViewController(
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), settings: settings,
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))),
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
        window.setContentSize(NSSize(width: 700, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        window.layoutIfNeeded()
        await fulfillment(of: [controlsReady], timeout: 5)
        func findText(in view: NSView) -> MacReaderTextView? {
            if let text = view as? MacReaderTextView { return text }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        let text = try XCTUnwrap(findText(in: controller.view))
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        func findTOCButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.action == NSSelectorFromString("showTOC:") {
                return button
            }
            return view.subviews.lazy.compactMap { findTOCButton(in: $0) }.first
        }
        if openTableOfContents {
            try XCTUnwrap(findTOCButton(in: controller.view)).performClick(nil)
        }
        XCTAssertEqual(text.string, currentText)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        XCTAssertEqual(text.onPageTap?(false), true)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(text.string, longText)
        let proposedEnd = max(0, text.frame.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, scroll.contentView.bounds.height)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.origin.y, proposedEnd + 1)
        let container = try XCTUnwrap(text.textContainer)
        let usedRect = try XCTUnwrap(text.layoutManager).usedRect(for: container)
        let visibleRect = scroll.contentView.documentVisibleRect
        XCTAssertLessThanOrEqual(
            usedRect.maxY,
            visibleRect.maxY + 0.5,
            "Every laid-out glyph must remain inside the final visible document rect."
        )
        XCTAssertLessThanOrEqual(
            visibleRect.maxY - usedRect.maxY,
            text.textContainerInset.height * 2 + 0.5,
            "The previous chapter must end without a large trailing gap."
        )
        let backwardProgress = try XCTUnwrap(ReaderProgressStore.read(bookId: identifier))
        XCTAssertEqual(backwardProgress.chapterIndex, 0)
        XCTAssertEqual(backwardProgress.offsetFraction, 1, accuracy: 0.001)
        XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 0)
        // Playback starts at the first visible glyph; reading progress is the scroll extent.
        var glyphViewport = scroll.contentView.documentVisibleRect
        glyphViewport.origin.y -= text.textContainerInset.height
        let manager = try XCTUnwrap(text.layoutManager)
        let visibleGlyphs = manager.glyphRange(forBoundingRect: glyphViewport, in: container)
        XCTAssertGreaterThan(visibleGlyphs.length, 0)
        let visibleAnchor = Double(manager.characterIndexForGlyph(at: visibleGlyphs.location)) / Double(text.string.utf16.count)
        XCTAssertEqual(standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey), visibleAnchor, accuracy: 0.001)
        XCTAssertEqual(text.onPageTap?(true), true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(text.string, currentText)
        XCTAssertGreaterThan(text.frame.height - scroll.contentView.bounds.height, scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        let forwardProgress = try XCTUnwrap(ReaderProgressStore.read(bookId: identifier))
        XCTAssertEqual(forwardProgress.chapterIndex, 1)
        XCTAssertEqual(forwardProgress.offsetFraction, 0, accuracy: 0.001)
        XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 1)
        XCTAssertEqual(standard.double(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey), 0, accuracy: 0.001)

        if openTableOfContents {
            // A subsequent selection must still navigate after highlight synchronization.
            try XCTUnwrap(findTOCButton(in: controller.view)).performClick(nil)
            func findChapterTable(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, table.delegate is MacReaderContentsPresentation { return table }
                return view.subviews.lazy.compactMap { findChapterTable(in: $0) }.first
            }
            let table = try XCTUnwrap(NSApp.windows.compactMap { candidate in
                candidate.contentView.flatMap { findChapterTable(in: $0) }
            }.first)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(text.string, longText)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
            XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 0)
        }
    }
}
#endif
