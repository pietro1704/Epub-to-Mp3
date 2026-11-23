#if os(iOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderListeningSessionTests: XCTestCase {
    private struct OpenFailure: Error {}

    private func book(_ id: String) -> BookEntity {
        BookEntity(id: id, title: id, bookmark: Data([1]),
                   displayFilename: "\(id).epub", addedAt: Date())
    }

    func testConstructingSessionNeverOpensOrStartsPlayback() throws {
        let suite = "reader-listening-standby-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var openCount = 0
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, _, _, _, _, _, _, _ in
                XCTFail("Constructing a reader must not start conversion")
                throw OpenFailure()
            }, currentBookID: { "book" },
            openBook: { _ in openCount += 1; throw OpenFailure() },
            recordConversion: { _, _ in XCTFail("No conversion was requested") },
            reportFailure: { _ in XCTFail("No file open was requested") }
        )
        session.observePlayback()
        session.observePlayback()
        XCTAssertFalse(session.isListening(to: "book"))
        XCTAssertEqual(openCount, 0)
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isConverting)
    }

    func testCancellationRejectsLateFileOpenBeforeItTouchesThePlayer() async throws {
        try await assertPendingOpenIsRejected(replacesBook: false)
    }

    func testBookReplacementRejectsLateFileOpenBeforeItTouchesThePlayer() async throws {
        try await assertPendingOpenIsRejected(replacesBook: true)
    }

    private func assertPendingOpenIsRejected(replacesBook: Bool) async throws {
        let suite = "reader-listening-identity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let started = expectation(description: "The original book open is pending")
        var pending: CheckedContinuation<URL, Error>?
        var activeBookID = "original"
        var conversions = 0
        var failures = 0
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, _, _, _, _, _, _, _ in
                conversions += 1
                throw OpenFailure()
            }, currentBookID: { activeBookID },
            openBook: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    pending = continuation
                    started.fulfill()
                }
            }, recordConversion: { _, _ in XCTFail("A retired open has no artifacts") },
            reportFailure: { _ in failures += 1 }
        )
        session.start(book: book("original"), priority: 0, pageRatio: nil,
                      catalog: [(index: 0, title: "Original chapter")],
                      conversionOptions: NarrationConversionOptions.current(for: AppSettings(defaults: defaults).ttsPreferences),
                      presentsFullPlayer: false, chapterEstimates: [0: 600])
        await fulfillment(of: [started], timeout: 2)
        if replacesBook { activeBookID = "replacement" }
        else { session.cancel() }
        let continuation = try XCTUnwrap(pending)
        continuation.resume(returning: URL(fileURLWithPath: "/unused/original.epub"))
        await session.waitForCompletion()
        XCTAssertEqual(conversions, 0)
        XCTAssertEqual(failures, 0)
        XCTAssertFalse(session.isListening(to: "original"))
        XCTAssertNil(player.snapshot)
        XCTAssertEqual(player.durationSeconds, 0, "A retired open must not install chapter estimates")
        XCTAssertFalse(player.isConverting)
    }

    func testCurrentOpenFailureReportsWithoutInstallingAPlaybackSession() async throws {
        let suite = "reader-listening-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var failures = 0
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, _, _, _, _, _, _, _ in
                XCTFail("A failed file open must not reach Rust")
                throw OpenFailure()
            }, currentBookID: { "missing" }, openBook: { _ in throw OpenFailure() },
            recordConversion: { _, _ in XCTFail("A failed open has no artifacts") },
            reportFailure: { _ in failures += 1 }
        )
        session.start(book: book("missing"), priority: 0, pageRatio: nil, catalog: [],
                      conversionOptions: NarrationConversionOptions.current(for: AppSettings(defaults: defaults).ttsPreferences),
                      presentsFullPlayer: false)
        await session.waitForCompletion()
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(session.isListening(to: "missing"))
        XCTAssertNil(player.snapshot)
        XCTAssertFalse(player.isConverting)
    }

    /// P0: switching the voice model while listening showed "Conversion cancelled" and playback never resumed.
    /// The switch retires the old job silently and the new job (new model, current position) keeps playing even
    /// while the player still republishes the retiring job's snapshot during the switch.
    func testSwitchingTheModelWhileListeningRetiresTheOldJobSilentlyAndKeepsPlaying() async throws {
        let suite = "reader-listening-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil))
        let cadu = NarrationConversionOptions.current(for: settings.ttsPreferences)
        settings.selectPrimaryNarration(TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil))
        let faber = NarrationConversionOptions.current(for: settings.ttsPreferences)

        var jobs: [(id: String, model: String?)] = []
        var failures: [Error] = []
        var oldJobEnded = false
        var opens = 0
        var secondOpen: CheckedContinuation<URL, Error>?
        let secondOpenPending = expectation(description: "The replacement's file open is pending")
        let session = ReaderListeningSession(
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, jobID, _, _, control, options, _, _, _ in
                jobs.append((jobID, options?.ttsPreferences?.primary.modelID))
                let isFirst = jobs.count == 1
                // Like Rust: a running job ends with a "cancelled" failure once its control is cancelled.
                while control?.isCancellationRequested != true, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                if isFirst { oldJobEnded = true }
                throw EmbeddedConverterError.conversionFailed("Conversion cancelled")
            },
            currentBookID: { "book" },
            openBook: { _ in
                opens += 1
                if opens == 1 { return URL(fileURLWithPath: "/unused/book.epub") }
                return try await withCheckedThrowingContinuation { continuation in
                    secondOpen = continuation
                    secondOpenPending.fulfill()
                }
            },
            recordConversion: { _, _ in }, reportFailure: { failures.append($0) }
        )
        session.observePlayback()
        session.start(book: book("book"), priority: 0, pageRatio: nil, catalog: [(index: 0, title: "One")],
                      conversionOptions: cadu, presentsFullPlayer: false, chapterEstimates: [0: 600])
        for _ in 0..<100 where player.snapshot?.jobId != jobs.first?.id || jobs.isEmpty {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let first = try XCTUnwrap(jobs.first, "The first listening job must be running")
        XCTAssertEqual(player.snapshot?.jobId, first.id)
        XCTAssertEqual(first.model, "pt_BR-cadu-medium")

        // The reader's model switch: the same book, from the current position, with the new model.
        let change = ReaderVoiceChange(chapter: 0, pageRatio: 0.3, seek: nil, autoplay: true)
        session.start(book: book("book"), priority: 0, pageRatio: 0.3, catalog: [(index: 0, title: "One")],
                      conversionOptions: faber, presentsFullPlayer: false, chapterEstimates: [0: 600], voiceChange: change)
        await fulfillment(of: [secondOpenPending], timeout: 3)
        // While the replacement prepares, the player keeps publishing the retiring job's snapshot.
        player.setSnapshot(try XCTUnwrap(player.snapshot))
        XCTAssertTrue(session.isListening(to: "book"), "Republishing the retiring job must not cancel its replacement")

        secondOpen?.resume(returning: URL(fileURLWithPath: "/unused/book.epub"))
        for _ in 0..<100 where jobs.count < 2 { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertEqual(jobs.count, 2, "The replacement job must start")
        XCTAssertEqual(jobs.last?.model, "pt_BR-faber-medium", "...with the new model")
        for _ in 0..<100 where !oldJobEnded { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(oldJobEnded, "The old job is cancelled")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(failures.isEmpty, "A retired job's cancellation is never shown as a failure: \(failures)")
        XCTAssertTrue(session.isListening(to: "book"), "Playback continues with the new job")
        XCTAssertEqual(player.snapshot?.jobId, jobs.last?.id)
        XCTAssertNotEqual(player.snapshot?.state, "failed")
        session.cancel()
    }
}
#endif
