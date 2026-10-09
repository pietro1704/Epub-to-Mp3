import AVFoundation
import XCTest
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
    var deliver: (@MainActor @Sendable (RustConversionCoordinator.ChapterCompletionEvent) -> Void)?
    lazy var controller = MainReaderScreenController(library: library, settings: AppSettings(defaults: defaults),
        player: player, playerPresentation: presentation,
        bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"), onBrowseLibrary: nil,
        conversionExecutor: { [weak self] _, job, start, end, _, callback in
            guard let self else { throw CancellationError() }
            self.calls += 1; self.job = job; self.requestedStart = start; self.requestedEnd = end
            self.deliver = callback
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
        XCTAssertEqual(f.requestedStart, 1); XCTAssertEqual(f.requestedEnd, -1)
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
