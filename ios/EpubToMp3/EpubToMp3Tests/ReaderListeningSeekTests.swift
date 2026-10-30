#if os(iOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderListeningSeekTests: XCTestCase {
    private struct OpenFailure: Error {}

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let suite = "listening-seek-\(UUID().uuidString)"
        let player: AudioPlayer
        var jobs: [String] = []
        var controls: [ConverterPlaybackControl] = []
        var conversions: [CheckedContinuation<RustConversionCoordinator.Result, Error>] = []
        var pendingOpens: [CheckedContinuation<URL, Error>] = []
        var openCount = 0
        var blockReopen = false
        var failures = 0
        lazy var session = ReaderListeningSession(player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { [weak self] _, job, _, _, control, _, _, _, _ in
                guard let self else { throw CancellationError() }
                jobs.append(job)
                controls.append(control)
                return try await withCheckedThrowingContinuation { self.conversions.append($0) }
            }, currentBookID: { "book" }, openBook: { [weak self] _ in
                guard let self else { throw CancellationError() }
                openCount += 1
                if blockReopen {
                    return try await withCheckedThrowingContinuation { self.pendingOpens.append($0) }
                }
                return URL(fileURLWithPath: "/unused/book.epub")
            }, recordConversion: { _, _ in XCTFail("The fixture has no completed conversion") },
            reportFailure: { [weak self] _ in self?.failures += 1 },
            makePlaybackControl: {
                ConverterPlaybackControl(rawHandle: UnsafeMutableRawPointer(bitPattern: 1)!,
                    free: { _ in }, cancel: { _ in }, prioritize: { _, _ in true },
                    setWindow: { _, _, _ in }, windowContains: { _, _ in true })
            })

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        }

        func start(ratio: Double) {
            session.observePlayback()
            session.start(book: BookEntity(id: "book", title: "Book", bookmark: Data([1]),
                displayFilename: "book.epub", addedAt: Date()), priority: 0, pageRatio: ratio,
                catalog: [(index: 0, title: "Chapter")], conversionOptions: ConversionOptions(),
                presentsFullPlayer: false, chapterEstimates: [0: 600])
        }

        @discardableResult
        func seek(_ position: TimeInterval, autoplay: Bool = false) throws -> UUID {
            let request = PendingPlaybackSeek.ChapterRequest(id: UUID(),
                jobID: try XCTUnwrap(player.snapshot?.jobId), chapterIndex: 0,
                autoplay: autoplay, position: position)
            player.restoreListeningSeek(request, jobID: request.jobID)
            return request.id
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("The listening transition did not finish")
        }

        func finish() {
            session.cancel()
            player.stop()
            conversions.forEach { $0.resume(throwing: CancellationError()) }
            pendingOpens.forEach { $0.resume(throwing: CancellationError()) }
            defaults.removePersistentDomain(forName: suite)
        }
    }

    func testApproximateRestartPreservesIdentityAndPausedIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        let request = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: fixture.jobs[0],
            chapterIndex: 0, autoplay: false, position: 300, navigationTarget: .approximateTime(0.5))
        fixture.player.restoreListeningSeek(request, jobID: request.jobID)
        try await fixture.waitUntil { fixture.jobs.count == 2 }
        let navigation = try XCTUnwrap(fixture.player.pendingNavigation)
        let restored = try XCTUnwrap(fixture.player.pendingListeningSeek(for: navigation))
        XCTAssertEqual(restored.id, request.id)
        XCTAssertEqual(navigation.target, .approximateTime(0.5))
        XCTAssertTrue(restored.startsAtGeneratedOrigin)
        XCTAssertFalse(restored.autoplay)
        XCTAssertFalse(fixture.player.isPlaying)
        XCTAssertTrue(fixture.controls[0].isCancellationRequested)
        XCTAssertTrue(fixture.player.isPositionApproximate)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.jobs.count, 2, "The restored suffix must not restart itself.")
    }

    func testApproximateRestartFailureClearsPendingRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.blockReopen = true
        let request = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: fixture.jobs[0],
            chapterIndex: 0, autoplay: true, position: 300, navigationTarget: .approximateTime(0.5))
        fixture.player.restoreListeningSeek(request, jobID: request.jobID)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }
        fixture.pendingOpens.removeFirst().resume(throwing: OpenFailure())
        await fixture.session.waitForCompletion()
        XCTAssertNil(fixture.player.pendingNavigation)
        XCTAssertFalse(fixture.player.isSeeking)
        XCTAssertFalse(fixture.player.isPlaying)
        XCTAssertEqual(fixture.failures, 1)
    }

    func testLatestApproximateSeekAndPauseWinDuringReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.blockReopen = true
        let job = fixture.jobs[0]
        let first = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: job,
            chapterIndex: 0, autoplay: true, position: 300, navigationTarget: .approximateTime(0.5))
        fixture.player.restoreListeningSeek(first, jobID: job)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }
        let latest = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: job,
            chapterIndex: 0, autoplay: true, position: 420, navigationTarget: .approximateTime(0.7))
        fixture.player.restoreListeningSeek(latest, jobID: job)
        fixture.player.pause()
        try await fixture.waitUntil { fixture.pendingOpens.count == 2 }
        let opens = fixture.pendingOpens
        fixture.pendingOpens.removeAll()
        opens.forEach { $0.resume(returning: URL(fileURLWithPath: "/unused/book.epub")) }
        try await fixture.waitUntil { fixture.jobs.count == 2 }
        let navigation = try XCTUnwrap(fixture.player.pendingNavigation)
        XCTAssertEqual(navigation.requestID, latest.id)
        XCTAssertEqual(navigation.target, .approximateTime(0.7))
        XCTAssertFalse(try XCTUnwrap(fixture.player.pendingListeningSeek(for: navigation)).autoplay)
        XCTAssertEqual(fixture.failures, 0)
    }

    func testStopRejectsLateApproximateReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.blockReopen = true
        let request = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: fixture.jobs[0],
            chapterIndex: 0, autoplay: true, position: 300, navigationTarget: .approximateTime(0.5))
        fixture.player.restoreListeningSeek(request, jobID: request.jobID)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }
        fixture.player.stop()
        fixture.pendingOpens.removeFirst().resume(returning: URL(fileURLWithPath: "/unused/book.epub"))
        await fixture.session.waitForCompletion()
        XCTAssertEqual(fixture.jobs.count, 1)
        XCTAssertNil(fixture.player.pendingNavigation)
        XCTAssertFalse(fixture.player.isPlaying)
        XCTAssertEqual(fixture.failures, 0)
    }

    func testTimelineSeekNeverUsesConflictingSavedReaderPage() async throws {
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) } }
        standard.set("book", forKey: keys[0])
        standard.set(0, forKey: keys[1])
        standard.set(0.9, forKey: keys[2])
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        let id = try fixture.seek(35)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fixture.jobs.count, 1, "A timeline seek must not restart at the saved reader page.")
        XCTAssertEqual(fixture.player.pendingNavigation?.requestID, id)
        XCTAssertEqual(fixture.player.pendingNavigation?.target, .chapterTime(35))
        XCTAssertEqual(fixture.player.positionSeconds, 35)
        XCTAssertFalse(fixture.controls[0].isCancellationRequested)
    }

    func testSuffixReplacementPreservesExactSecondsIdentityAndPauseIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0.7)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        let id = try fixture.seek(35)
        try await fixture.waitUntil { fixture.jobs.count == 2 }
        XCTAssertNotEqual(fixture.jobs[0], fixture.jobs[1])
        XCTAssertTrue(fixture.controls[0].isCancellationRequested)
        XCTAssertFalse(fixture.controls[1].isCancellationRequested)
        let navigation = try XCTUnwrap(fixture.player.pendingNavigation)
        XCTAssertEqual(navigation.requestID, id)
        XCTAssertEqual(navigation.jobID, fixture.jobs[1])
        XCTAssertEqual(navigation.target, .chapterTime(35))
        XCTAssertEqual(fixture.player.positionSeconds, 35)
        XCTAssertFalse(try XCTUnwrap(fixture.player.pendingListeningSeek(for: navigation)).autoplay)
        XCTAssertFalse(fixture.player.isPlaying)
    }

    func testLatestSeekWhileBookReopensSupersedesTheRetiredOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0.7)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.blockReopen = true
        _ = try fixture.seek(35)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }
        let latest = try fixture.seek(155, autoplay: true)
        fixture.player.pause()
        try await fixture.waitUntil { fixture.pendingOpens.count == 2 }
        let opens = fixture.pendingOpens
        fixture.pendingOpens.removeAll()
        opens[0].resume(returning: URL(fileURLWithPath: "/unused/retired.epub"))
        opens[1].resume(returning: URL(fileURLWithPath: "/unused/current.epub"))
        try await fixture.waitUntil { fixture.jobs.count == 2 }
        XCTAssertEqual(fixture.player.pendingNavigation?.requestID, latest)
        XCTAssertEqual(fixture.player.pendingNavigation?.target, .chapterTime(155))
        let navigation = try XCTUnwrap(fixture.player.pendingNavigation)
        XCTAssertFalse(try XCTUnwrap(fixture.player.pendingListeningSeek(for: navigation)).autoplay,
            "Pause during file access must override the captured autoplay intent.")
        XCTAssertEqual(fixture.failures, 0)
    }

    func testStopDuringSuffixReopenCannotRestoreCancelledSeek() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0.7)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.blockReopen = true
        _ = try fixture.seek(35)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }
        fixture.player.stop()
        let open = fixture.pendingOpens.removeFirst()
        open.resume(returning: URL(fileURLWithPath: "/unused/cancelled.epub"))
        await fixture.session.waitForCompletion()
        XCTAssertEqual(fixture.jobs.count, 1)
        XCTAssertNil(fixture.player.pendingNavigation)
        XCTAssertFalse(fixture.player.isSeeking)
        XCTAssertEqual(fixture.failures, 0)
    }

    func testCurrentSuffixReopenFailureCancelsWaitingSeekAndReportsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0.7)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.blockReopen = true
        _ = try fixture.seek(35)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }
        let open = fixture.pendingOpens.removeFirst()
        open.resume(throwing: OpenFailure())
        await fixture.session.waitForCompletion()
        XCTAssertEqual(fixture.jobs.count, 1)
        XCTAssertNil(fixture.player.pendingNavigation)
        XCTAssertFalse(fixture.player.isSeeking)
        XCTAssertFalse(fixture.player.isConverting)
        XCTAssertEqual(fixture.failures, 1)
    }

    func testBookReplacementRejectsLateReopenWithoutChangingTheNewSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0.7)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.blockReopen = true
        _ = try fixture.seek(35)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }
        let replacement = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"replacement-book","state":"running","chapterProgress":[]}"#.utf8))
        fixture.player.play(snapshot: replacement, restoreAutoplay: false)
        let open = fixture.pendingOpens.removeFirst()
        open.resume(returning: URL(fileURLWithPath: "/unused/retired.epub"))
        await fixture.session.waitForCompletion()
        XCTAssertEqual(fixture.jobs.count, 1)
        XCTAssertEqual(fixture.player.snapshot?.jobId, "replacement-book")
        XCTAssertNil(fixture.player.pendingNavigation)
        XCTAssertEqual(fixture.failures, 0)
    }
}
#endif
