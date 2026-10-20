import AVFoundation
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import EpubToMp3

@MainActor
private struct ListeningDefaultsSnapshot {
    private let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
        AudioPlayer.currentChapterIndexDefaultsKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
        AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
    private let values: [Any?]
    private let widgetBook: Any?
    init() {
        values = keys.map { UserDefaults.standard.object(forKey: $0) }
        widgetBook = UserDefaults(suiteName: WidgetDataSync.appGroupID)?.object(forKey: "currentlyPlayingBookId")
    }
    func restore() {
        for (key, value) in zip(keys, values) { UserDefaults.standard.set(value, forKey: key) }
        UserDefaults(suiteName: WidgetDataSync.appGroupID)?.set(widgetBook, forKey: "currentlyPlayingBookId")
    }
}

private func writeListeningFixtureAudio(at url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000))
    buffer.frameLength = buffer.frameCapacity
    try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(buffer.frameLength))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

@MainActor
final class AudioPlayerPendingPlayIntentTests: XCTestCase {
    func testPauseBeforeChapterDeliveryRevokesPendingAutoplay() throws {
        let id = "pending-play-\(UUID().uuidString)"
        let sharedDefaults = ListeningDefaultsSnapshot()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).wav")
        try writeListeningFixtureAudio(at: audio)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop(); sharedDefaults.restore(); defaults.removePersistentDomain(forName: id); try? FileManager.default.removeItem(at: audio) }
        UserDefaults.standard.removeObject(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        UserDefaults.standard.removeObject(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let event = RustConversionCoordinator.ChapterCompletionEvent(jobId: id, bookTitle: "Book", bookAuthor: "Author",
            chapterIndex: 0, chaptersTotal: 1, chaptersCompleted: 1, chapterTitle: "Chapter",
            filename: audio.lastPathComponent, audioPath: audio, textChars: 100)
        player.play(snapshot: event.snapshot(chapters: []), restoreAutoplay: false)
        player.resume()
        player.pause()
        player.updateSnapshot(event.snapshot(chapters: [event.playableChapter]))
        XCTAssertNotNil(player.testHook_currentPlayerItem())
        XCTAssertFalse(player.isPlaying, "Pause must revoke Play intent before the first audio arrives")
    }
}

#if os(iOS)
@MainActor
private final class ProgressiveListeningFixture {
    let id: String
    let defaults: UserDefaults
    let root: URL
    let source: URL
    let library: LibraryStore
    let book: BookEntity
    let player: AudioPlayer
    let presentation: PlayerPresentation
    let stream: AsyncStream<Void>
    let release: AsyncStream<Void>.Continuation
    private let sharedDefaults = ListeningDefaultsSnapshot()
    var calls = 0
    var job: String?
    var requestedStart: Int32?
    var requestedEnd: Int32?
    var finished = false
    var fail = false
    var omitPriority = false
    var playbackControl: ConverterPlaybackControl?
    var deliver: (@MainActor @Sendable (RustConversionCoordinator.ChapterCompletionEvent) -> Void)?
    var deliverChunk: (@Sendable (Int, Int, Data) -> Bool)?
    lazy var controller = MainReaderScreenController(library: library, settings: AppSettings(defaults: defaults),
        player: player, playerPresentation: presentation,
        bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onBrowseLibrary: nil,
        conversionExecutor: { [weak self] _, job, start, end, control, options, _, callback, chunk in
            guard let self else { throw CancellationError() }
            XCTAssertEqual(options?.engine, "piper")
            XCTAssertEqual(options?.ttsPreferences?.primary.modelID, "pt_BR-faber-medium")
            XCTAssertEqual(options?.ttsPreferences?.secondary?.engine, "system")
            XCTAssertEqual(options?.ttsPreferences?.policyVersion, 2)
            XCTAssertEqual(options?.ttsPreferences?.allowOnlineFallback, false)
            control.updatePlaybackWindow(currentChapter: Int(start), chaptersAhead: 1)
            self.playbackControl = control
            self.calls += 1; self.job = job; self.requestedStart = start; self.requestedEnd = end
            self.deliver = callback
            self.deliverChunk = chunk
            for await _ in self.stream { }
            self.finished = true
            if self.fail { throw EmbeddedConverterError.conversionFailed("Fixture failure") }
            let chapters: [[String: Any]] = (self.omitPriority ? [2] : [1, 2]).map {
                ["sourceIndex": $0, "filename": "ch\($0).wav", "title": "Chapter \($0)", "textChars": 100]
            }
            let bytes = try JSONSerialization.data(withJSONObject: ["manifest": [
                "jobId": job, "title": "Fixture", "author": "Author", "chapters": chapters]])
            return .init(jobID: job, manifestJSON: bytes, outputDirectory: self.root)
        }, sessionDefaults: defaults)

    init() throws {
        let identifier = "reader-listen-\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = try EpubFixture.createWithChapters(["Front matter", "Current chapter", "Next chapter"])
        let store = LibraryStore(defaults: prefs, defaultsKey: "library", importDirectory: directory.appendingPathComponent("imports"))
        let imported = try store.importBook(from: input)
        id = identifier; defaults = prefs; root = directory; source = input; library = store; book = imported
        player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: prefs)))
        presentation = PlayerPresentation(defaults: prefs)
        var continuation: AsyncStream<Void>.Continuation!
        stream = AsyncStream { continuation = $0 }; release = continuation
        try writeListeningFixtureAudio(at: root.appendingPathComponent("ch1.wav"))
        try writeListeningFixtureAudio(at: root.appendingPathComponent("ch2.wav"))
        defaults.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        defaults.set(1, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        UserDefaults.standard.set(book.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
    }

    func cleanup() {
        release.finish(); player.stop()
        sharedDefaults.restore()
        defaults.removePersistentDomain(forName: id)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: source)
    }

    func emit(_ chapter: Int, jobID: String? = nil) throws {
        let callback = try XCTUnwrap(deliver)
        callback(.init(jobId: try jobID ?? XCTUnwrap(job), bookTitle: "Fixture", bookAuthor: "Author",
            chapterIndex: chapter, chaptersTotal: 2, chaptersCompleted: 1, chapterTitle: "Chapter \(chapter)",
            filename: "ch\(chapter).wav", audioPath: root.appendingPathComponent("ch\(chapter).wav"), textChars: 100))
    }

    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Native progressive-listening condition timed out")
    }

    func complete() async throws {
        release.finish()
        try await wait { library.books.first(where: { $0.id == book.id })?.lastJobId == job }
    }
}

@MainActor
final class ReaderProgressiveListeningTests: XCTestCase {
    func testMiniPlayerPreservesPageUntilCompleteChapterArrives() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.defaults.set(0.5, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        let chunk = try XCTUnwrap(f.deliverChunk)
        let data = try Data(contentsOf: f.root.appendingPathComponent("ch1.wav"))
        let accepted = await Task.detached { chunk(1, 0, data) }.value
        XCTAssertTrue(accepted, "Rust must keep building the canonical complete chapter")
        XCTAssertNil(f.player.testHook_currentPlayerItem(), "A chapter ratio must never seek inside its first segment")
        try f.emit(1, jobID: "foreign-job")
        try f.emit(2)
        XCTAssertNil(f.player.testHook_currentPlayerItem())
        try f.emit(1)
        try await f.wait { !f.player.isSeeking && (f.player.testHook_currentPlayerItem()?.currentTime().seconds ?? 0) >= 7.4 }
        XCTAssertEqual(f.player.positionSeconds, 7.5, accuracy: 0.5)
        XCTAssertTrue(f.player.isPlaying)
        XCTAssertFalse(f.presentation.showingFullPlayer)
        f.player.pause()
        try await f.complete()
        XCTAssertFalse(f.player.isPlaying)
    }

    func testMiniPlayerPageStartKeepsPauseWhileWaitingForChapter() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.defaults.set(0.4, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        f.player.pause()
        f.player.nextChapter()
        f.player.previousChapter()
        XCTAssertEqual(f.player.pendingNavigation?.chapterIndex, 1,
                       "Navigation before the first playable chapter must retain the page request")
        try f.emit(1)
        try await f.wait { !f.player.isSeeking && (f.player.testHook_currentPlayerItem()?.currentTime().seconds ?? 0) >= 5.9 }
        XCTAssertFalse(f.player.isPlaying, "A late chapter must not undo Pause")
        XCTAssertEqual(f.player.positionSeconds, 6, accuracy: 0.1)
        try await f.complete()
        XCTAssertFalse(f.player.isPlaying)
    }

    func testMiniPlayerRejectsNonfinitePageAnchorAndStreamsImmediately() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.defaults.set(Double.nan, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        let chunk = try XCTUnwrap(f.deliverChunk)
        let data = try Data(contentsOf: f.root.appendingPathComponent("ch1.wav"))
        let accepted = await Task.detached { chunk(1, 0, data) }.value
        XCTAssertTrue(accepted)
        XCTAssertNotNil(f.player.testHook_currentPlayerItem())
        XCTAssertNil(f.player.pendingNavigation)
        f.player.pause()
        try f.emit(1)
        try await f.complete()
    }

    func testTerminalEmptySnapshotDoesNotWaitForReaderPageForever() throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        for state in ["finished", "failed", "cancelled"] {
            let data = try JSONSerialization.data(withJSONObject: ["jobId": "terminal-empty", "state": state])
            let terminal = try JSONDecoder().decode(JobSnapshot.self, from: data)
            XCTAssertTrue(terminal.isTerminal)
            f.player.play(snapshot: terminal, restoreAutoplay: false)
            f.player.startFromReaderPage(1, sentenceOffsetRatio: 0.5)
            XCTAssertNil(f.player.pendingNavigation)
            XCTAssertFalse(f.player.isSeeking)
            XCTAssertFalse(f.player.isPlaying)
            XCTAssertNotNil(f.player.lastError)
        }
    }

    func testMiniPlayerPageAnchorDoesNotSurviveReplacementSession() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.defaults.set(0.5, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        let chunk = try XCTUnwrap(f.deliverChunk)
        let foreign = RustConversionCoordinator.ChapterCompletionEvent(jobId: "replacement", bookTitle: "Other", bookAuthor: "Author",
            chapterIndex: 0, chaptersTotal: 1, chaptersCompleted: 1, chapterTitle: "Other",
            filename: "ch1.wav", audioPath: f.root.appendingPathComponent("ch1.wav"), textChars: 100).snapshot(chapters: [])
        f.player.stop(); f.player.setSnapshot(foreign)
        let data = try Data(contentsOf: f.root.appendingPathComponent("ch1.wav"))
        let accepted = await Task.detached { chunk(1, 0, data) }.value
        XCTAssertFalse(accepted)
        try f.emit(1)
        try await f.complete()
        XCTAssertEqual(f.player.snapshot, foreign)
        XCTAssertNil(f.player.pendingNavigation)
        XCTAssertFalse(f.player.isPlaying)
    }

    func testExpandedPlayerDisplaysActualFallbackVoiceAndRefreshesOnPrimaryRecovery() throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        let fallback = try JSONDecoder().decode(JobSnapshot.self, from: Data(#"{"jobId":"voice-fixture","state":"running","engine":"system","voice":"Luciana (installed.luciana)"}"#.utf8))
        f.player.setSnapshot(fallback)
        let controller = FullPlayerScreenController(player: f.player, playbackClock: f.player.playbackClock,
            library: f.library, playerPresentation: f.presentation, settings: AppSettings(defaults: f.defaults))
        func labels(in view: UIView) -> [String] {
            ((view as? UILabel)?.text.map { [$0] } ?? []) + view.subviews.flatMap { labels(in: $0) }
        }
        XCTAssertTrue(labels(in: controller.view).contains { $0.contains("Luciana") })
        XCTAssertFalse(labels(in: controller.view).contains { $0.contains("installed.luciana") })
        let recovered = try JSONDecoder().decode(JobSnapshot.self, from: Data(#"{"jobId":"voice-fixture","state":"running","engine":"piper","voice":"pt_BR-faber-medium"}"#.utf8))
        f.player.setSnapshot(recovered)
        controller.refresh(library: f.library)
        XCTAssertTrue(labels(in: controller.view).contains { $0.contains("Faber medium") })
        XCTAssertFalse(labels(in: controller.view).contains { $0.contains("Luciana") })
    }

    func testBookReplacementCancelsRustControlAndRetiredCompletionDoesNotRecordJob() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        let retiring = try XCTUnwrap(f.playbackControl)
        let source = try EpubFixture.createWithChapters(["Another book first", "Another book second"])
        defer { try? FileManager.default.removeItem(at: source) }
        let replacement = try f.library.importBook(from: source)
        f.defaults.set(replacement.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        // Rendering a replacement reader is the normal context replacement boundary.
        f.controller.loadViewIfNeeded()
        XCTAssertTrue(retiring.isCancellationRequested)
        XCTAssertNil(f.player.snapshot)
        f.release.finish()
        try await f.wait { f.finished }
        await Task.yield()
        XCTAssertNil(f.library.books.first(where: { $0.id == f.book.id })?.lastJobId)
        XCTAssertNil(f.player.snapshot)
    }

    func testExplicitAudioRemovalCancelsOnlyMatchingListeningJob() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.loadViewIfNeeded()
        try await f.wait { !f.controller.isLoadingBookContent }
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        let control = try XCTUnwrap(f.playbackControl)
        NotificationCenter.default.post(name: RustConversionOutputStore.willRemoveAudio,
                                         object: nil, userInfo: ["bookID": "another-book"])
        XCTAssertFalse(control.isCancellationRequested)
        NotificationCenter.default.post(name: RustConversionOutputStore.willRemoveAudio,
                                         object: nil, userInfo: ["bookID": f.book.id])
        XCTAssertTrue(control.isCancellationRequested)
        XCTAssertNil(f.player.snapshot)
        f.release.finish()
        try await f.wait { f.finished }
        await Task.yield()
        XCTAssertNil(f.library.books.first(where: { $0.id == f.book.id })?.lastJobId)
    }

    func testNextBeforeSecondChapterDeliveryPreservesPauseAndUpdatesPlaybackWindow() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        let payload = try JSONDecoder().decode(EbookFulltext.self, from: JSONSerialization.data(withJSONObject: [
            "jobId": f.book.id, "chapters": (1...3).map {
                ["index": $0, "name": "Chapter \($0 - 1)", "text": "Fixture text"]
            }
        ]))
        LocalFulltextCache.save(payload, bookId: f.book.id)
        ReaderProgressStore.save(bookId: f.book.id, chapterIndex: 1, offsetFraction: 0)
        defer {
            ReaderProgressStore.evict(bookId: f.book.id)
            LocalFulltextCache.evictInMemoryPayload(bookId: f.book.id)
            if let url = LocalFulltextCache.storageURL(bookId: f.book.id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        f.controller.loadViewIfNeeded()
        try await f.wait { !f.controller.isLoadingBookContent }
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        XCTAssertEqual(f.player.snapshot?.chapterProgress?.map(\.index), [0, 1, 2])
        XCTAssertEqual(f.player.snapshot?.playableChapters.count, 0)
        let data = try Data(contentsOf: f.root.appendingPathComponent("ch1.wav"))
        f.player.enqueueSegment(data: data, chapterIndex: 1, segmentIndex: 0)
        f.player.pause()
        try f.emit(1)
        XCTAssertEqual(f.player.snapshot?.chapterProgress?.map(\.index), [0, 1, 2],
            "Completed chapter publication must retain pending navigation metadata")
        f.player.nextChapter()
        try await f.wait { f.player.pendingNavigation?.chapterIndex == 2 && f.playbackControl?.contains(chapterIndex: 1) == false }
        XCTAssertTrue(try XCTUnwrap(f.playbackControl).contains(chapterIndex: 2))
        XCTAssertFalse(f.player.isPlaying)
        f.player.enqueueSegment(data: data, chapterIndex: 2, segmentIndex: 0)
        try f.emit(2)
        try await f.wait { f.player.activeStreamingChapterIndex == 2 && !f.player.isSeeking }
        XCTAssertEqual(f.player.activeStreamingChapterIndex, 2)
        XCTAssertFalse(f.player.isPlaying, "Arrival must retain the user's paused navigation intent")
        try await f.complete()
        XCTAssertFalse(f.player.isPlaying)
        XCTAssertEqual(f.player.currentChapterIndex, 1,
                       "A partial zero-based manifest must preserve the selected chapter during full-file handoff.")
        let asset = try XCTUnwrap(f.player.testHook_currentPlayerItem()?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.lastPathComponent, "ch2.wav")
    }

    func testNewListeningRequestPreservesPreviousMeaningfulResumePosition() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        let previous = "\(f.id)-previous"
        let event = RustConversionCoordinator.ChapterCompletionEvent(jobId: previous,
            bookTitle: "Previous book", bookAuthor: "Author", chapterIndex: 0,
            chaptersTotal: 1, chaptersCompleted: 0, chapterTitle: "Previous",
            filename: "ch1.wav", audioPath: f.root.appendingPathComponent("ch1.wav"), textChars: 100)
        f.player.setSnapshot(event.snapshot(chapters: []))
        f.player.playbackClock.update(positionSeconds: 4)
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        let stored = ResumeStore(storage: UserDefaultsResumeStorage(defaults: f.defaults))
        let marker = try XCTUnwrap(stored.marker(jobId: previous, chapterIndex: 0))
        XCTAssertEqual(marker.positionSeconds, 4, accuracy: 0.001)
        XCTAssertFalse(marker.wasPlaying, "Switching books must not arm autoplay of the prior session")
        try f.emit(1); f.player.pause(); try await f.complete()
    }

    func testUnrepresentablePriorityDoesNotStartConversionOrAlterPlayback() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.defaults.set(Int.max, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        f.controller.startListeningFromMiniPlayer()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(f.calls, 0); XCTAssertNil(f.player.snapshot)
    }

    func testRequestedChapterPlaysBeforeConversionFinishesWithoutRestart() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.startListeningFromMiniPlayer()
        try await f.wait { f.calls == 1 }
        XCTAssertEqual(f.requestedStart, 1)
        XCTAssertEqual(f.requestedEnd, -1, "The control window schedules only the active chapter and one ahead")
        f.controller.startListeningFromMiniPlayer()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(f.calls, 1, "Repeated Play must not queue another conversion")
        try f.emit(1, jobID: "foreign-job")
        try f.emit(2)
        XCTAssertNil(f.player.testHook_currentPlayerItem(), "An out-of-order later chapter cannot start playback")
        try f.emit(1)
        try await f.wait { (f.player.testHook_currentPlayerItem()?.currentTime().seconds ?? 0) > 0.1 }
        let item = try XCTUnwrap(f.player.testHook_currentPlayerItem())
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, f.root.appendingPathComponent("ch1.wav"))
        XCTAssertTrue(f.player.isPlaying); XCTAssertFalse(f.finished)
        XCTAssertEqual(f.player.snapshot?.playableChapters.map(\.index), [1, 2])
        f.player.pause()
        try await f.complete()
        XCTAssertTrue(f.player.testHook_currentPlayerItem() === item)
        XCTAssertFalse(f.player.isPlaying, "Finalization must not undo a user's pause")
        XCTAssertFalse(f.player.isConverting)
        XCTAssertFalse(f.presentation.showingFullPlayer, "Mini player Play must keep the reader visible")
    }

    func testPauseWhileWaitingPreventsChapterAutoplay() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.startListeningFromMiniPlayer(); try await f.wait { f.calls == 1 }
        f.player.pause(); try f.emit(1)
        XCTAssertNotNil(f.player.testHook_currentPlayerItem()); XCTAssertFalse(f.player.isPlaying)
        try await f.complete(); XCTAssertFalse(f.player.isPlaying)
    }

    func testBookChangedBeforeDeliveryDoesNotAutoplayOldBook() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.startListeningFromMiniPlayer(); try await f.wait { f.calls == 1 }
        f.defaults.removeObject(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        try f.emit(1); XCTAssertNil(f.player.testHook_currentPlayerItem())
        try await f.complete(); XCTAssertFalse(f.player.isPlaying)
    }

    func testReplacementPlayerSessionIgnoresOldDeliveryAndCompletion() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.startListeningFromMiniPlayer(); try await f.wait { f.calls == 1 }
        let foreign = RustConversionCoordinator.ChapterCompletionEvent(jobId: "\(f.id)-foreign", bookTitle: "Other", bookAuthor: "Author",
            chapterIndex: 0, chaptersTotal: 1, chaptersCompleted: 1, chapterTitle: "Other",
            filename: "ch1.wav", audioPath: f.root.appendingPathComponent("ch1.wav"), textChars: 100).snapshot(chapters: [])
        f.player.stop(); f.player.setSnapshot(foreign)
        let converting = f.player.isConverting
        try f.emit(1); try await f.complete()
        XCTAssertEqual(f.player.snapshot, foreign); XCTAssertFalse(f.player.isPlaying)
        XCTAssertEqual(f.player.isConverting, converting, "An old job must not change the replacement session's conversion state")
    }

    func testFailureWhileBrowsingAnotherBookEndsConvertingWithoutStoppingAudio() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.startListeningFromMiniPlayer(); try await f.wait { f.calls == 1 }
        try f.emit(1)
        try await f.wait { (f.player.testHook_currentPlayerItem()?.currentTime().seconds ?? 0) > 0.1 }
        let item = f.player.testHook_currentPlayerItem()
        f.defaults.removeObject(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        f.fail = true; f.release.finish()
        try await f.wait { f.player.snapshot?.state == "failed" }
        XCTAssertFalse(f.player.isConverting); XCTAssertTrue(f.player.isPlaying)
        XCTAssertTrue(f.player.testHook_currentPlayerItem() === item)
    }

    func testTerminalManifestMissingPriorityDoesNotStartAnotherChapter() async throws {
        let f = try ProgressiveListeningFixture(); defer { f.cleanup() }
        f.controller.startListeningFromMiniPlayer(); try await f.wait { f.calls == 1 }
        f.defaults.removeObject(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        f.omitPriority = true; f.release.finish()
        try await f.wait { f.player.snapshot?.state == "failed" }
        XCTAssertFalse(f.player.isPlaying); XCTAssertNil(f.player.testHook_currentPlayerItem())
        XCTAssertNil(f.library.books.first(where: { $0.id == f.book.id })?.lastJobId)
    }
}
#endif
