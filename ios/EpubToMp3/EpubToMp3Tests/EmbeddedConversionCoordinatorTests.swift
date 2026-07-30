import XCTest
@testable import EpubToMp3

final class EmbeddedConversionCoordinatorTests: XCTestCase {
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

    func testAudioPlayerResolvesEmbeddedFileURLs() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Services/AudioPlayer.swift")
        )
        XCTAssertTrue(source.contains("hasPrefix(\"file://\")"))
        XCTAssertTrue(source.contains("URL(fileURLWithPath: path)"))
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
