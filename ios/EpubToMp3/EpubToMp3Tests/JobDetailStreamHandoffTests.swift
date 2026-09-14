#if os(iOS)
import AVFoundation
import UIKit
import XCTest
@testable import EpubToMp3

private actor HandoffChunkGate {
    private let data: Data
    private var released = false
    private var continuation: CheckedContinuation<Data, Never>?

    init(data: Data) { self.data = data }

    func wait() async -> Data {
        if released { return data }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private final class HandoffStreamingClient: JobStreamingClient, @unchecked Sendable {
    let enteredDownload: XCTestExpectation
    let completedDownloadCycle: XCTestExpectation
    let gate: HandoffChunkGate
    private let initial: JobSnapshot
    private let manifest: APIClient.ChapterStreamManifest
    private let events: AsyncThrowingStream<JobEvent, Error>
    private let eventContinuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    private let lock = NSLock()
    private var fetchCount = 0

    init(initial: JobSnapshot, manifest: APIClient.ChapterStreamManifest, data: Data,
         entered: XCTestExpectation, completed: XCTestExpectation) {
        self.initial = initial
        self.manifest = manifest
        gate = HandoffChunkGate(data: data)
        enteredDownload = entered
        completedDownloadCycle = completed
        var continuation: AsyncThrowingStream<JobEvent, Error>.Continuation!
        events = AsyncThrowingStream { continuation = $0 }
        eventContinuation = continuation
    }

    private func recordSnapshotFetch() {
        lock.lock()
        fetchCount += 1
        let completedCycle = fetchCount == 2
        lock.unlock()
        if completedCycle { completedDownloadCycle.fulfill() }
    }

    func fetchJob(id: String) async throws -> JobSnapshot {
        recordSnapshotFetch()
        return initial
    }

    func fetchChapterStream(jobId: String, chapterIndex: Int) async throws -> APIClient.ChapterStreamManifest {
        manifest
    }

    func fetchChapterStreamChunk(jobId: String, chapterIndex: Int, chunkId: String) async throws -> Data {
        enteredDownload.fulfill()
        return await gate.wait()
    }

    func eventStream(jobId: String) -> AsyncThrowingStream<JobEvent, Error> { events }

    func publish(_ snapshot: JobSnapshot) throws {
        let payload = try JSONEncoder().encode(snapshot)
        eventContinuation.yield(.init(receivedAt: Date(), rawPayload: String(decoding: payload, as: UTF8.self)))
    }

    func finish() { eventContinuation.finish() }
}

final class JobDetailStreamHandoffTests: XCTestCase {
    @MainActor
    func testExplicitPlayOfAnotherJobKeepsItsSubsequentSnapshotsAttached() async throws {
        let identifier = "ExplicitJobPlay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidgetBook = widget?.object(forKey: "currentlyPlayingBookId")
        widget?.set("", forKey: "currentlyPlayingBookId")
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier)-first.wav")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier)-second.wav")
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widget?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: firstURL, settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.copyItem(at: firstURL, to: secondURL)
        func snapshot(jobID: String, secondReady: Bool) -> JobSnapshot {
            JobSnapshot(jobId: jobID, state: "running", bookTitle: "Explicit play fixture", bookAuthor: nil,
                coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
                progressPercent: secondReady ? 100 : 50, chaptersTotal: 2, chaptersCompleted: secondReady ? 2 : 1,
                chapterProgress: [
                    .init(index: 1, name: "First", status: "completed", downloadUrl: firstURL.absoluteString,
                          chars: 100, charsProcessed: 100, progressRatio: 1, durationSeconds: 1,
                          startedAt: nil, completedAt: nil),
                    .init(index: 2, name: "Second", status: secondReady ? "completed" : "pending",
                          downloadUrl: secondReady ? secondURL.absoluteString : nil, chars: 100,
                          charsProcessed: secondReady ? 100 : 0, progressRatio: secondReady ? 1 : 0,
                          durationSeconds: 1, startedAt: nil, completedAt: nil)
                ], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        }
        let jobA = "\(identifier)-A"
        let jobB = "\(identifier)-B"
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        standard.set(jobA, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(jobA, forKey: AudioPlayer.currentBookIDDefaultsKey)
        player.play(snapshot: snapshot(jobID: jobA, secondReady: false), startingAt: 0)
        let originalItem = try XCTUnwrap(player.testHook_currentPlayerItem())
        let entered = expectation(description: "Job B initial snapshot and chunk fetch reached the live controller")
        let client = HandoffStreamingClient(initial: snapshot(jobID: jobB, secondReady: false),
            manifest: .init(chapterIndex: 1, chunks: [.init(id: UUID().uuidString, index: 0, url: "/unused", text: nil)]),
            data: try Data(contentsOf: firstURL), entered: entered,
            completed: XCTestExpectation(description: "Unused polling boundary"))
        let settings = AppSettings(defaults: defaults)
        settings.backendURL = "https://explicit-job-play.invalid"
        let controller = JobDetailScreenController(jobId: jobB, settings: settings,
            library: LibraryStore(defaults: defaults), player: player, playbackClock: PlaybackClock(),
            streamingClient: client)
        let navigation = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: UIScreen.main.bounds)
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer {
            navigation.setViewControllers([], animated: false)
            controller.viewDidDisappear(false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            client.finish()
            Task { await client.gate.release() }
            player.stop()
        }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(player.snapshot?.jobId, jobA,
                       "Merely opening job B must not replace the existing player.")
        XCTAssertTrue(player.testHook_currentPlayerItem() === originalItem)
        standard.set(jobB, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(jobB, forKey: AudioPlayer.currentBookIDDefaultsKey)
        let playRow = (0..<controller.numberOfSections(in: controller.tableView)).flatMap { section in
            (0..<controller.tableView(controller.tableView, numberOfRowsInSection: section)).map {
                IndexPath(row: $0, section: section)
            }
        }.first { indexPath in
            let cell = controller.tableView(controller.tableView, cellForRowAt: indexPath)
            return (cell.contentConfiguration as? UIListContentConfiguration)?.text == L10n.string("player.play")
        }
        controller.tableView(controller.tableView, didSelectRowAt: try XCTUnwrap(playRow))
        let child = try XCTUnwrap(navigation.topViewController as? PlayerScreenController)
        child.loadViewIfNeeded()
        XCTAssertEqual(player.snapshot?.jobId, jobB,
                       "The real Play action and child controller must accept the user's selected job before the SSE assertion.")
        try client.publish(snapshot(jobID: jobB, secondReady: true))
        for _ in 0..<100 {
            if player.snapshot?.playableChapters.count == 2 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(player.snapshot?.playableChapters.count, 2,
                       "Explicitly accepted job B must retain its live snapshot binding behind the player screen.")
        player.nextChapter()
        let secondItem = try XCTUnwrap(player.testHook_currentPlayerItem())
        XCTAssertEqual((secondItem.asset as? AVURLAsset)?.url, secondURL,
                       "The newly published chapter must reach the actual audio queue.")
    }

    @MainActor
    func testInFlightChunkCannotReenterSegmentModeAfterSnapshotPublishesFullFile() async throws {
        let identifier = "Handoff-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidgetBook = widget?.object(forKey: "currentlyPlayingBookId")
        widget?.set("", forKey: "currentlyPlayingBookId")
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(identifier, forKey: AudioPlayer.currentBookIDDefaultsKey)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier).wav")
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widget?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: url)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        func snapshot(completed: Bool) -> JobSnapshot {
            JobSnapshot(jobId: identifier, state: "running", bookTitle: "Handoff fixture", bookAuthor: nil,
                coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
                progressPercent: completed ? 50 : 0, chaptersTotal: 2, chaptersCompleted: completed ? 1 : 0,
                chapterProgress: [.init(index: 1, name: "First", status: completed ? "completed" : "processing",
                    downloadUrl: completed ? url.absoluteString : nil, chars: 100,
                    charsProcessed: completed ? 100 : 0, progressRatio: completed ? 1 : 0,
                    durationSeconds: 1, startedAt: nil, completedAt: nil)],
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        }
        let producer = try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
            #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":40,"artifactPublishedElapsedNanoseconds":55}"#.utf8))
        let entered = expectation(description: "Chunk download is suspended")
        let completed = expectation(description: "Chunk callback returned before the next polling cycle")
        let client = HandoffStreamingClient(initial: snapshot(completed: false),
            manifest: .init(chapterIndex: 1, chunks: [.init(id: UUID().uuidString, index: 0,
                url: "/unused", text: nil, observation: producer)]),
            data: try Data(contentsOf: url), entered: entered, completed: completed)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let settings = AppSettings(defaults: defaults)
        settings.backendURL = "https://handoff.invalid"
        let controller = JobDetailScreenController(jobId: identifier, settings: settings,
            library: LibraryStore(defaults: defaults), player: player, playbackClock: PlaybackClock(),
            streamingClient: client)
        defer {
            controller.viewDidDisappear(false)
            client.finish()
            Task { await client.gate.release() }
            player.stop()
        }
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertNil(player.testHook_currentPlayerItem())
        try client.publish(snapshot(completed: true))
        for _ in 0..<100 {
            if player.testHook_currentPlayerItem() != nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let fullFile = try XCTUnwrap(player.testHook_currentPlayerItem())
        XCTAssertEqual((fullFile.asset as? AVURLAsset)?.url, url)
        await client.gate.release()
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertTrue(player.testHook_currentPlayerItem() === fullFile)
        XCTAssertEqual(player.testHook_retainedSegmentCount(), 0,
                       "The actual controller must not relabel an in-flight stream with the full-file generation.")
    }
}
#endif
