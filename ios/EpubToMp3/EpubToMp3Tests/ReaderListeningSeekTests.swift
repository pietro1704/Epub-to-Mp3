import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderListeningSeekTests: XCTestCase {
    private struct OpenFailure: Error {}
    private final class ListeningPositions { var requests: [[String: Int]] = [] }

    @MainActor
    private final class Fixture {
        let defaults: UserDefaults
        let suite = "listening-seek-\(UUID().uuidString)"
        let player: AudioPlayer
        var jobs: [String] = []
        var options: [ConversionOptions?] = []
        var progress: [(@MainActor @Sendable (RustConversionCoordinator.ConversionProgressEvent) -> Void)?] = []
        var preparedChapter: (@MainActor @Sendable (RustConversionCoordinator.ChapterCompletionEvent) -> Void)?
        var controls: [ConverterPlaybackControl] = []
        let listeningPositions = ListeningPositions()
        var conversions: [CheckedContinuation<RustConversionCoordinator.Result, Error>] = []
        var pendingOpens: [CheckedContinuation<URL, Error>] = []
        var openCount = 0
        var blockReopen = false
        var failures = 0
        var currentBookID = "book"
        lazy var session = ReaderListeningSession(player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { [weak self] _, job, _, _, control, options, progress, preparedChapter, _ in
                guard let self else { throw CancellationError() }
                jobs.append(job)
                self.options.append(options)
                self.progress.append(progress)
                self.preparedChapter = preparedChapter
                controls.append(control)
                return try await withCheckedThrowingContinuation { self.conversions.append($0) }
            }, currentBookID: { [weak self] in self?.currentBookID }, openBook: { [weak self] _ in
                guard let self else { throw CancellationError() }
                openCount += 1
                if blockReopen {
                    return try await withCheckedThrowingContinuation { self.pendingOpens.append($0) }
                }
                return URL(fileURLWithPath: "/unused/book.epub")
            }, recordConversion: { _, _ in XCTFail("The fixture has no completed conversion") },
            reportFailure: { [weak self] _ in self?.failures += 1 },
            makePlaybackControl: { [weak self] in
                guard let self else { throw CancellationError() }
                let handle = Unmanaged.passUnretained(listeningPositions).toOpaque()
                return ConverterPlaybackControl(rawHandle: handle,
                    free: { _ in }, cancel: { _ in }, prioritize: { _, _ in true },
                    setWindow: { _, _, _ in }, windowContains: { _, _ in true },
                    listeningPosition: { raw, json in
                        guard let raw, let json,
                              let request = try? JSONDecoder().decode([String: Int].self,
                                  from: Data(String(cString: json).utf8)) else { return false }
                        Unmanaged<ListeningPositions>.fromOpaque(UnsafeMutableRawPointer(mutating: raw))
                            .takeUnretainedValue().requests.append(request)
                        return true
                    })
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

    func testBookSwitchDuringInitialOpenDoesNotInstallRetiredPlayback() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.blockReopen = true
        fixture.start(ratio: 0.25)
        try await fixture.waitUntil { fixture.pendingOpens.count == 1 }

        fixture.currentBookID = "replacement-book"
        fixture.pendingOpens.removeFirst().resume(returning: URL(fileURLWithPath: "/unused/retired.epub"))
        await fixture.session.waitForCompletion()

        XCTAssertTrue(fixture.jobs.isEmpty)
        XCTAssertNil(fixture.session.listeningJobID)
        XCTAssertNil(fixture.player.snapshot)
        XCTAssertEqual(fixture.failures, 0)
    }

    func testPreparedChapterRetainsReportedFallbackAndPause() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(fixture.suite).mp3")
        try LegacyAudioImportFixture.audio.write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        fixture.start(ratio: 0)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        fixture.player.pause()
        let jobID = try XCTUnwrap(fixture.jobs.first)
        try XCTUnwrap(fixture.progress.first ?? nil)(.init(jobId: jobID, state: "running", chapterIndex: 0,
            chaptersTotal: 1, chaptersCompleted: 0, percent: 10, engine: "system", message: "Fallback"))
        try XCTUnwrap(fixture.preparedChapter)(.init(jobId: jobID, bookTitle: "Book", bookAuthor: "Author",
            chapterIndex: 0, chaptersTotal: 1, chaptersCompleted: 1, chapterTitle: "Chapter",
            filename: audio.lastPathComponent, audioPath: audio, textChars: 100))

        XCTAssertEqual(fixture.player.snapshot?.jobId, jobID)
        XCTAssertEqual(fixture.player.snapshot?.engine, "system")
        XCTAssertEqual(fixture.player.snapshot?.playableChapters.map(\.index), [0])
        XCTAssertFalse(fixture.player.isPlaying)
        XCTAssertFalse(fixture.player.hasPendingAutoplay)
    }

    func testCurrentConversionFailureRetiresItsControlAndReportsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0)
        try await fixture.waitUntil { fixture.conversions.count == 1 }
        let jobID = try XCTUnwrap(fixture.jobs.first)
        let control = try XCTUnwrap(fixture.controls.first)

        fixture.conversions.removeFirst().resume(throwing: OpenFailure())
        await fixture.session.waitForCompletion()

        XCTAssertTrue(control.isCancellationRequested)
        XCTAssertEqual(fixture.player.snapshot?.jobId, jobID)
        XCTAssertEqual(fixture.player.snapshot?.state, "failed")
        XCTAssertFalse(fixture.player.isPlaying)
        XCTAssertEqual(fixture.failures, 1)
    }

    func testVoiceChangeDuringPreparationUsesExplicitSelectionAndRejectsRetiredProgress() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.start(ratio: 0.4)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        let target = try XCTUnwrap(fixture.session.startingVoicePosition)
        XCTAssertEqual(target.chapter, 0)
        XCTAssertEqual(target.pageRatio, 0.4)

        let selected = TtsSelection.systemDefault
        var explicit = ConversionOptions(forceReprocess: true)
        explicit.ttsPreferences = .init(primary: selected, secondary: nil, allowOnlineFallback: false)
        fixture.session.start(book: BookEntity(id: "book", title: "Book", bookmark: Data([1]),
            displayFilename: "book.epub", addedAt: Date()), priority: target.chapter, pageRatio: target.pageRatio,
            catalog: [(index: 0, title: "Chapter")], conversionOptions: explicit, presentsFullPlayer: false,
            voiceChange: target)
        try await fixture.waitUntil { fixture.jobs.count == 2 }
        XCTAssertTrue(fixture.controls[0].isCancellationRequested)
        XCTAssertEqual(fixture.options[1]?.ttsPreferences?.primary, selected)
        XCTAssertEqual(fixture.options[1]?.forceReprocess, true)
        fixture.progress[0]?(.init(jobId: fixture.jobs[0], state: "running", chapterIndex: 0,
            chaptersTotal: 1, chaptersCompleted: 0, percent: 90, engine: "retired", message: "Retired progress"))

        XCTAssertEqual(fixture.player.snapshot?.jobId, fixture.jobs[1])
        XCTAssertNotEqual(fixture.player.snapshot?.engine, "retired")
        XCTAssertEqual(fixture.session.requestedVoice, selected)
    }

    func testVoiceChangeFromPDFSelectionPreservesExactOffsetWithoutEPUBMap() async throws {
        let fixture = try Fixture()
        defer { fixture.finish() }
        let text = "Earlier words. The selected PDF position."
        let metadata = try JSONSerialization.data(withJSONObject: ["chapters": [
            ["index": "1", "name": "Earlier chapter", "sourcePath": "page-1", "text": "Earlier"],
            ["index": "2", "name": "Selected chapter", "sourcePath": "page-2", "text": text],
        ]])
        let map = try PDFReadingAudioMap(metadata: metadata, pageTexts: ["Earlier", text])
        let word = try XCTUnwrap(text.range(of: "selected"))
        let anchor = try XCTUnwrap(map.anchor(page: 1, character: word.lowerBound.utf16Offset(in: text)))
        let book = BookEntity(id: "book", title: "Book", bookmark: Data([1]),
            displayFilename: "book.pdf", addedAt: Date(), fileType: .pdf)

        fixture.session.start(book: book, priority: anchor.chapterIndex, pageRatio: nil, catalog: [],
            conversionOptions: ConversionOptions(), presentsFullPlayer: false, pdfAnchor: anchor)
        try await fixture.waitUntil { fixture.jobs.count == 1 }
        let original = try XCTUnwrap(fixture.listeningPositions.requests.last)
        XCTAssertEqual(original["chapter_index"], 1)
        XCTAssertEqual(original["text_offset"], anchor.sourceScalarOffset)
        XCTAssertGreaterThan(anchor.sourceScalarOffset, 0)

        let target = try XCTUnwrap(fixture.session.startingVoicePosition)
        var options = ConversionOptions(forceReprocess: true)
        options.ttsPreferences = .init(primary: .systemDefault, secondary: nil, allowOnlineFallback: false)
        fixture.session.start(book: book, priority: target.chapter, pageRatio: target.pageRatio, catalog: [],
            conversionOptions: options, presentsFullPlayer: false, voiceChange: target)
        try await fixture.waitUntil { fixture.jobs.count == 2 }

        XCTAssertEqual(fixture.controls.first?.isCancellationRequested, true)
        XCTAssertEqual(fixture.options.last.flatMap { $0 }?.ttsPreferences?.primary, .systemDefault)
        XCTAssertEqual(fixture.listeningPositions.requests.last?["chapter_index"], original["chapter_index"])
        XCTAssertEqual(fixture.listeningPositions.requests.last?["text_offset"], original["text_offset"])
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
        let fixture = try Fixture()
        defer { fixture.finish() }
        fixture.player.location.setReadingBook("book")
        fixture.player.location.setReaderAnchor(chapter: 0, pageRatio: 0.9)
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
