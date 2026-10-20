#if os(macOS)
import AppKit
import AVFoundation
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderPagePlaybackChoiceTests: XCTestCase {
    func testFinalVisibleReaderPagePublishesTextStartInsteadOfChapterEnd() async throws {
        let id = "mac-page-anchor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey,
                    "readerProgress.v1", "readerWarmBookIDs.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        let body = String(repeating: "Reader page anchor preserves the beginning of the final visible page. ", count: 100)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root)
        let source = try EpubFixture.createWithChapter(body: body, includeCover: false)
        let book = try library.importBook(from: source)
        let fulltext = EbookFulltext(jobId: id, bookTitle: book.title, bookAuthor: nil,
            chapters: [.init(index: 1, name: "Chapter", text: body, html: nil, css: nil,
                             charCount: body.count, segments: nil)])
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let restoredPosition = expectation(description: "Saved reader position has committed")
        let reader = MacReaderViewController(library: library, settings: settings, player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onClose: {},
            preparedFulltextReader: { _ in fulltext }, preparedFulltextWriter: { _, _ in },
            initialPositionScheduler: { operation in
                DispatchQueue.main.async {
                    operation()
                    restoredPosition.fulfill()
                }
            })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: id)
            for url in [root, source] { try? FileManager.default.removeItem(at: url) }
        }
        window.contentViewController = reader
        window.makeKeyAndOrderFront(nil)
        reader.setBook(book.id)
        // Text can be laid out before the queued initial-position restore.
        // Scroll notifications intentionally ignore that restoration phase.
        await fulfillment(of: [restoredPosition], timeout: 10)
        var scroll: NSScrollView?
        for _ in 0..<100 {
            reader.view.layoutSubtreeIfNeeded()
            scroll = descendants(in: reader.view).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView as? NSTextView)?.string.contains("Reader page anchor") == true
            }
            if let scroll, (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let viewport = try XCTUnwrap(scroll)
        let document = try XCTUnwrap(viewport.documentView)
        let end = max(document.frame.height - viewport.contentView.bounds.height, 0)
        XCTAssertGreaterThan(end, 100)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: end))
        viewport.reflectScrolledClipView(viewport.contentView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: viewport)
        let ratio = try XCTUnwrap(standard.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double)
        XCTAssertGreaterThan(ratio, 0)
        XCTAssertLessThan(ratio, 1, "The final reader page starts before the audio chapter's final word.")
        XCTAssertEqual(ReaderProgressStore.read(bookId: book.id)?.offsetFraction ?? 0, 1, accuracy: 0.001,
                       "The audio anchor must not change persisted reader geometry.")
    }

    func testActualPlayerBarOffersPageChoiceAndRetainsContinuation() async throws {
        let id = "mac-reader-page-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey,
                    "readerProgress.v1", "readerWarmBookIDs.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                          "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                          "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                          "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let savedWidget = widgetKeys.map { widget?.object(forKey: $0) }
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root)
        let source = try EpubFixture.createWithChapter(body: String(repeating: "Reader playback page test. ", count: 50), includeCover: false)
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            player.stop()
            window.orderOut(nil)
            window.contentViewController = nil
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: id)
            for url in [root, source] { try? FileManager.default.removeItem(at: url) }
        }
        library.recordConversion(jobId: id, for: book.id)
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.0, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        standard.removeObject(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
        let audio = root.appendingPathComponent("chapter.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        let chapter = JobSnapshot.Chapter(index: 0, name: "Page choice", status: "completed",
            downloadUrl: audio.absoluteString, chars: 1300, charsProcessed: 1300,
            progressRatio: 1, durationSeconds: 60, startedAt: nil, completedAt: nil)
        let snapshot = JobSnapshot(jobId: id, state: "finished", bookTitle: "Mac reader choice",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "fixture", voice: nil, language: nil,
            progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1, chapterProgress: [chapter],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        player.play(snapshot: snapshot, restoreAutoplay: false)
        let controller = MacAppKitRootController(settings: AppSettings(defaults: defaults), library: library,
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
        for _ in 0..<30 where item.status == .unknown { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        // Let startup reader restoration finish before driving transport.
        try await Task.sleep(nanoseconds: 500_000_000)
        standard.set(0.0, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        player.resume()
        player.pause()
        standard.set(0.6, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        // Transport notifications and the AVPlayer observer update AppKit on
        // subsequent run-loop turns; wait for the actual paused control.
        for _ in 0..<20 where !buttons(in: controller.view).contains(where: {
            $0.toolTip == L10n.string("player.play")
        }) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(player.isPlaying)
        let play = try XCTUnwrap(buttons(in: controller.view).first { $0.toolTip == L10n.string("player.play") })
        play.performClick(nil)
        let sheet = try await waitForSheet(window)
        let page = try XCTUnwrap(buttons(in: try XCTUnwrap(sheet.contentView)).first {
            $0.title == L10n.string("player.divergence.fromCurrentPage")
        })
        page.performClick(nil)
        try await waitForPlayback(player, minimum: 35)
        player.pause()
        let pausedAt = player.positionSeconds
        standard.set(0.0, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        play.performClick(nil)
        let continuationSheet = try await waitForSheet(window)
        let continuation = try XCTUnwrap(buttons(in: try XCTUnwrap(continuationSheet.contentView)).first {
            $0.title == L10n.string("player.divergence.fromWhereStopped")
        })
        continuation.performClick(nil)
        try await waitForPlayback(player, minimum: pausedAt - 1)
        XCTAssertLessThan(player.positionSeconds, pausedAt + 3)
        XCTAssertFalse(buttons(in: controller.view).contains {
            $0.accessibilityIdentifier() == "reader.playCurrentPage"
        })
        standard.set(0.3, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        play.performClick(nil)
        XCTAssertFalse(player.isPlaying, "A page turn while playing must preserve normal Pause.")
        let cancelledAt = player.positionSeconds
        play.performClick(nil)
        let cancelSheet = try await waitForSheet(window)
        let sheetButtons = buttons(in: try XCTUnwrap(cancelSheet.contentView))
        XCTAssertEqual(Set(sheetButtons.map(\.title)), Set([
            L10n.string("player.divergence.fromWhereStopped"),
            L10n.string("player.divergence.fromCurrentPage"), L10n.string("common.cancel")
        ]))
        let cancel = try XCTUnwrap(sheetButtons.first { $0.title == L10n.string("common.cancel") })
        cancel.performClick(nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.positionSeconds, cancelledAt, accuracy: 0.5)
        play.performClick(nil)
        let newPageSheet = try await waitForSheet(window)
        try XCTUnwrap(buttons(in: try XCTUnwrap(newPageSheet.contentView)).first {
            $0.title == L10n.string("player.divergence.fromCurrentPage")
        }).performClick(nil)
        try await waitForPlayback(player, minimum: 17)
        player.pause()
        play.performClick(nil)
        XCTAssertNil(window.attachedSheet, "Unchanged reader page must resume without another choice.")
        XCTAssertTrue(player.isPlaying)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func waitForSheet(_ window: NSWindow) async throws -> NSWindow {
        for _ in 0..<30 where window.attachedSheet == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        return try XCTUnwrap(window.attachedSheet, "Paused Play after reader movement must offer a choice.")
    }

    private func waitForPlayback(_ player: AudioPlayer, minimum: Double) async throws {
        for _ in 0..<50 where !player.isPlaying || player.isSeeking || player.positionSeconds < minimum {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(player.isSeeking)
        XCTAssertGreaterThanOrEqual(player.positionSeconds, minimum)
    }
}
#endif
