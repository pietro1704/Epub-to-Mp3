import XCTest
@testable import EpubToMp3

final class EmbeddedConversionCoordinatorTests: XCTestCase {
    private enum WarmupProbeError: LocalizedError {
        case unavailable

        var errorDescription: String? { "Embedded audio probe unavailable" }
    }

    private func source(_ relativePath: String) throws -> String {
        try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3")
                .appendingPathComponent(relativePath)
        )
    }

    func testEmbeddedJobIDIsStablePerBook() {
        XCTAssertEqual(
            EmbeddedConversionCoordinator.jobID(for: "book-hash"),
            "embedded-book-hash"
        )
    }

    func testLocalCachePolicyHonorsClearAndForceReprocess() {
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localCacheAction(
                clearCache: false,
                forceReprocess: false
            ),
            .reuse
        )
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localCacheAction(
                clearCache: false,
                forceReprocess: true
            ),
            .regenerateOutputs
        )
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localCacheAction(
                clearCache: true,
                forceReprocess: false
            ),
            .clearBook
        )
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localCacheAction(
                clearCache: true,
                forceReprocess: true
            ),
            .clearBook,
            "Clear cache must win because it removes both prepared text and output."
        )
    }

    func testMaxPerformanceSelectsOrderedParallelStreaming() {
        XCTAssertEqual(
            EmbeddedConversionCoordinator.streamingMode(maxPerformance: false),
            .lowestLatencySerial
        )
        XCTAssertEqual(
            EmbeddedConversionCoordinator.streamingMode(maxPerformance: true),
            .orderedParallel,
            "High-performance streaming must use the bounded parallel transport with its reorder barrier."
        )
    }

    func testEmbeddedChapterRetriesHaveABoundedAutomaticLimit() {
        XCTAssertEqual(EmbeddedConversionCoordinator.maximumAutomaticChapterAttempts, 2)
    }

    func testRequestedChapterDownloadsUseIndependentSchedulingKeys() {
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localSchedulingKey(
                drivesPlayer: false,
                requestedChapterIndices: [3]
            ),
            "download-chapters-3"
        )
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localSchedulingKey(
                drivesPlayer: false,
                requestedChapterIndices: [5]
            ),
            "download-chapters-5"
        )
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localSchedulingKey(
                drivesPlayer: false,
                requestedChapterIndices: nil
            ),
            "download-all"
        )
        XCTAssertEqual(
            EmbeddedConversionCoordinator.localSchedulingKey(
                drivesPlayer: true,
                requestedChapterIndices: [3]
            ),
            "playback"
        )
    }

    func testPriorityChapterOrderStartsAtTheRequestedChapterAndPreservesBookOrderAfterward() {
        XCTAssertEqual(
            EmbeddedConversionCoordinator.prioritizedChapterIndices(
                source: [0, 1, 2, 3, 4],
                priorities: [3, 1, 99, 3]
            ),
            [3, 1, 0, 2, 4]
        )
    }

    func testReusableSnapshotRejectsAFinishedButPartialChapterRequest() {
        let snapshot = JobSnapshot(
            jobId: "embedded-book",
            state: "finished",
            bookTitle: "Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: "edge",
            voice: nil,
            language: nil,
            progressPercent: 50,
            chaptersTotal: 2,
            chaptersCompleted: 1,
            chapterProgress: [
                .init(index: 1, name: "Downloaded chapter", status: "completed", downloadUrl: "file:///chapter.mp3", chars: 10, charsProcessed: 10, progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil)
            ],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )

        XCTAssertFalse(EmbeddedConversionCoordinator.isReusableCompletedSnapshot(snapshot))
    }

    func testCanonicalSpeechTextRequiresThePythonPreparedPayload() {
        let canonical = EbookFulltext(
            jobId: "book",
            bookTitle: "Book",
            bookAuthor: nil,
            chapters: [
                .init(
                    index: 1,
                    name: "Chapter One",
                    text: "Reader-facing text",
                    speechText: "Chapter One. ... Canonical audible text.",
                    html: nil,
                    css: nil,
                    charCount: 20,
                    segments: nil
                )
            ]
        )
        let legacy = EbookFulltext(
            jobId: "book",
            bookTitle: "Book",
            bookAuthor: nil,
            chapters: [
                .init(
                    index: 1,
                    name: "Chapter One",
                    text: "Reader-facing text",
                    html: nil,
                    css: nil,
                    charCount: 20,
                    segments: nil
                )
            ]
        )

        XCTAssertTrue(EmbeddedConversionCoordinator.hasCanonicalSpeechText(canonical))
        XCTAssertFalse(
            EmbeddedConversionCoordinator.hasCanonicalSpeechText(legacy),
            "A pre-speech cache must be reparsed instead of silently narrating reader text."
        )
    }

    func testReusableAudioRejectsPartialAndNonMP3Files() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reusable-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("partial.mp3")
        try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: partial)
        XCTAssertFalse(EmbeddedConversionCoordinator.isReusableAudio(at: partial))

        let response = root.appendingPathComponent("response.mp3")
        try Data(repeating: 0x3C, count: 1_024).write(to: response)
        XCTAssertFalse(EmbeddedConversionCoordinator.isReusableAudio(at: response))

        let valid = root.appendingPathComponent("valid.mp3")
        var bytes = Data([0xFF, 0xFB, 0x90, 0x00])
        bytes.append(Data(repeating: 0, count: 1_020))
        try bytes.write(to: valid)
        XCTAssertTrue(EmbeddedConversionCoordinator.isReusableAudio(at: valid))
    }

    @MainActor
    func testAudioWarmupRunsTheReadinessProbeOnlyOnceAfterSuccess() async {
        var calls = 0
        let warmup = AudioEngineWarmup {
            calls += 1
        }

        let first = await warmup.start()
        let second = await warmup.start()

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(warmup.state, .ready)
        XCTAssertEqual(warmup.progress, 1)
    }

    @MainActor
    func testAudioWarmupSurfacesPreflightFailureInsteadOfReportingReady() async {
        let warmup = AudioEngineWarmup {
            throw WarmupProbeError.unavailable
        }

        let isReady = await warmup.start()

        XCTAssertFalse(isReady)
        XCTAssertEqual(warmup.progress, 0)
        guard case .failed(let message) = warmup.state else {
            return XCTFail("Warmup must expose a failed state when the Python preflight fails.")
        }
        XCTAssertEqual(message, "Embedded audio probe unavailable")
    }

    func testReconciledSnapshotUsesCachedTOCTitleForGenericEmbeddedChapter() {
        let genericChapter = JobSnapshot.Chapter(
            index: 1,
            name: "Capítulo 1",
            status: "completed",
            downloadUrl: "file:///chapter-1.mp3",
            chars: 100,
            charsProcessed: 100,
            progressRatio: 1,
            durationSeconds: nil,
            startedAt: nil,
            completedAt: nil
        )
        let snapshot = JobSnapshot(
            jobId: "embedded-book",
            state: "finished",
            bookTitle: "The Lord of the Rings",
            bookAuthor: "J.R.R. Tolkien",
            coverUrl: nil,
            coverMimeType: nil,
            engine: "edge",
            voice: nil,
            language: nil,
            progressPercent: 100,
            chaptersTotal: 1,
            chaptersCompleted: 1,
            chapterProgress: [genericChapter],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
        let fulltext = EbookFulltext(
            jobId: "book",
            bookTitle: "The Lord of the Rings",
            bookAuthor: "J.R.R. Tolkien",
            chapters: [
                .init(
                    index: 1,
                    name: "A Long-expected Party",
                    text: "Bilbo was very rich and very peculiar.",
                    html: nil,
                    css: nil,
                    charCount: 40,
                    segments: nil
                )
            ]
        )

        let reconciled = EmbeddedConversionCoordinator.reconciledSnapshot(
            snapshot,
            fulltext: fulltext
        )

        XCTAssertEqual(reconciled.chapterProgress?.first?.name, "A Long-expected Party")
    }

    func testReconciledSnapshotPreservesARealTitleAndRepairsZeroBasedLegacyIndex() {
        let snapshot = JobSnapshot(
            jobId: "embedded-book",
            state: "finished",
            bookTitle: "The Lord of the Rings",
            bookAuthor: "J.R.R. Tolkien",
            coverUrl: nil,
            coverMimeType: nil,
            engine: "edge",
            voice: nil,
            language: nil,
            progressPercent: 100,
            chaptersTotal: 2,
            chaptersCompleted: 2,
            chapterProgress: [
                .init(index: 0, name: "Chapter 1", status: "completed", downloadUrl: "file:///one.mp3", chars: nil, charsProcessed: nil, progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil),
                .init(index: 1, name: "Prologue", status: "completed", downloadUrl: "file:///two.mp3", chars: nil, charsProcessed: nil, progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil)
            ],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
        let fulltext = EbookFulltext(
            jobId: "book",
            bookTitle: "The Lord of the Rings",
            bookAuthor: "J.R.R. Tolkien",
            chapters: [
                .init(index: 1, name: "A Long-expected Party", text: "Text", html: nil, css: nil, charCount: 4, segments: nil),
                .init(index: 2, name: "The Shadow of the Past", text: "Text", html: nil, css: nil, charCount: 4, segments: nil)
            ]
        )

        let reconciled = EmbeddedConversionCoordinator.reconciledSnapshot(
            snapshot,
            fulltext: fulltext
        )

        XCTAssertEqual(reconciled.chapterProgress?[0].name, "A Long-expected Party")
        XCTAssertEqual(reconciled.chapterProgress?[1].name, "Prologue")
    }

    func testTerminalLiveSnapshotRetainsFailedChaptersForTheTOC() {
        let chapters = [
            EbookFulltext.Chapter(index: 1, name: "Prologue", text: "Opening", html: nil, css: nil, charCount: 7, segments: nil),
            EbookFulltext.Chapter(index: 2, name: "Chapter One", text: "Body", html: nil, css: nil, charCount: 4, segments: nil),
        ]
        let completed = JobSnapshot.Chapter(
            index: 1,
            name: "Prologue",
            status: "completed",
            downloadUrl: "file:///prologue.mp3",
            chars: 7,
            charsProcessed: 7,
            progressRatio: 1,
            durationSeconds: nil,
            startedAt: nil,
            completedAt: nil
        )

        let snapshot = EmbeddedConversionCoordinator.liveSnapshot(
            bookID: "book",
            title: "Book",
            author: nil,
            engine: "edge",
            voice: "voice",
            language: nil,
            narratable: chapters,
            completed: [completed],
            errors: ["Chapter 2: synthesis failed"],
            state: "failed"
        )

        XCTAssertEqual(snapshot.state, "failed")
        XCTAssertEqual(snapshot.chaptersTotal, 2)
        XCTAssertEqual(snapshot.chaptersCompleted, 1)
        XCTAssertEqual(snapshot.chapterProgress?.map(\.status), ["completed", "failed"])
        XCTAssertEqual(snapshot.playableChapters.map(\.index), [1])
    }

    func testAudioPlayerResolvesEmbeddedFileURLs() {
        let resolved = AudioPlayer.playbackURL(
            forDownloadPath: "file:///private/var/mobile/chapter-1.mp3",
            backendBaseURL: nil
        )

        XCTAssertEqual(resolved?.isFileURL, true)
        XCTAssertEqual(resolved?.path, "/private/var/mobile/chapter-1.mp3")
    }

    func testBookDetailUsesEmbeddedConversionWhenTheDeviceProviderIsSelected() throws {
        let iosSource = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Library/Views/BookDetailScreenController.swift")
        )
        let macSource = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Library/Views/MacBookDetailViewController.swift")
        )
        XCTAssertTrue(iosSource.contains("EmbeddedConversionCoordinator.stream"))
        XCTAssertTrue(iosSource.contains("jobId.hasPrefix(\"embedded-\")"))
        XCTAssertTrue(iosSource.contains("backendBaseURL: nil"))
        XCTAssertTrue(iosSource.contains("DownloadManager.shared.enqueueAll(snapshot: snapshot, baseURL: nil)"))
        XCTAssertTrue(macSource.contains("EmbeddedConversionCoordinator.stream"))
        XCTAssertTrue(macSource.contains("startRemoteConversion"))
        XCTAssertTrue(macSource.contains("recordConversion(jobId: response.jobId"))
        XCTAssertTrue(macSource.contains("alert.informativeText = error.localizedDescription"))
        XCTAssertTrue(macSource.contains("remoteStreamTask = Task {"))
    }

    func testEmbeddedConversionHasSegmentStreamingPath() throws {
        let coordinatorSource = try source("Features/Conversion/Services/EmbeddedConversionCoordinator.swift")
        let playerSource = try source("Features/Playback/Services/AudioPlayer.swift")
        XCTAssertTrue(coordinatorSource.contains("static func stream("))
        XCTAssertTrue(coordinatorSource.contains("convertChapterStreaming"))
        XCTAssertTrue(coordinatorSource.contains("player.enqueueSegment"))
        XCTAssertTrue(playerSource.contains("finishEmbeddedStreaming"))
        XCTAssertTrue(playerSource.contains("canonical chapter queue"))
    }
}
