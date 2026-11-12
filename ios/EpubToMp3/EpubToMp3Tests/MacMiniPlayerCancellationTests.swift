#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacMiniPlayerCancellationTests: XCTestCase {
    func testNativeDismissCancelsListeningRejectsLateCallbacksAndKeepsManualConversion() async throws {
        let suite = "MiniCancellation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
        let input = try EpubFixture.createWithChapter(body: "A local cancellation fixture. \(suite)", includeCover: false)
        let book = try library.importBook(from: input)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.readerCurrentSentenceIdDefaultsKey, AudioPlayer.currentBookIDDefaultsKey,
            AudioPlayer.currentChapterIndexDefaultsKey, "readerProgress.v1", "readerWarmBookIDs.v1",
            "player.dismissedMiniPlayerBooks.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var control: ConverterPlaybackControl?
        var progress: (@MainActor @Sendable (RustConversionCoordinator.ConversionProgressEvent) -> Void)?
        var chunk: (@Sendable (Int, Int, Data) -> Bool)?
        var streaming: CheckedContinuation<RustConversionCoordinator.Result, Error>?
        var manualPending: CheckedContinuation<RustConversionCoordinator.Result, Error>?
        var jobID = ""
        let listeningStarted = expectation(description: "Listening conversion is active")
        let manualStarted = expectation(description: "Independent manual conversion is active")
        let manual = ManualConversionSession(executor: { _, _, _, _, _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                manualPending = continuation
                manualStarted.fulfill()
            }
        })
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.1, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        let root = MacAppKitRootController(settings: AppSettings(defaults: defaults), library: library,
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, job, _, _, activeControl, _, onProgress, _, onChunk in
                jobID = job
                control = activeControl
                progress = onProgress
                chunk = onChunk
                return try await withCheckedThrowingContinuation { continuation in
                    streaming = continuation
                    listeningStarted.fulfill()
                }
            })
        let window = NSWindow(contentViewController: root)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 650))
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer {
            player.stop()
            manual.cancel()
            streaming?.resume(throwing: CancellationError())
            manualPending?.resume(throwing: CancellationError())
            for controller in root.presentedViewControllers ?? [] { root.dismiss(controller) }
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            for url in [directory, input] { try? FileManager.default.removeItem(at: url) }
        }
        let manualTask = Task { await manual.run(file: input, start: 0, end: 0, options: nil) }
        root.startPlaybackForCurrentBook()
        await fulfillment(of: [listeningStarted, manualStarted], timeout: 10)
        let activeControl = try XCTUnwrap(control)
        XCTAssertFalse(activeControl.isCancellationRequested)
        XCTAssertEqual(player.snapshot?.jobId, jobID)
        XCTAssertTrue(player.isConverting)
        let manualID = manual.requestID
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let dismiss = try XCTUnwrap(descendants(root.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "miniPlayer.dismiss" })
        dismiss.performClick(nil)
        XCTAssertTrue(activeControl.isCancellationRequested)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isConverting)
        XCTAssertNil(player.snapshot)
        XCTAssertTrue(manual.isRunning)
        XCTAssertEqual(manual.requestID, manualID)
        progress?(.init(jobId: jobID, state: "running", chapterIndex: 0,
            chaptersTotal: 1, chaptersCompleted: 0, percent: 90, engine: "retired", message: "Retired progress"))
        let staleChunk = chunk
        let accepted = await Task.detached { staleChunk?(0, 0, Data([1, 2])) }.value
        XCTAssertEqual(accepted, false)
        XCTAssertNil(player.snapshot)
        XCTAssertTrue(manual.isRunning)
        XCTAssertTrue(MiniPlayerDismissal().isDismissed(bookID: book.id))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(dismiss.isHiddenOrHasHiddenAncestor, "Late callbacks cannot restore the dismissed native bar")
        manual.cancel()
        manualPending?.resume(throwing: CancellationError())
        manualPending = nil
        await manualTask.value
    }
}
#endif
