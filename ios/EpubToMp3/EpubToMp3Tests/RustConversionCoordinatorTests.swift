import XCTest
@testable import EpubToMp3
import AVFoundation
import Darwin

final class RustConversionCoordinatorTests: XCTestCase {
    func testConversionLogAppendPreservesPreviousChunkTrace() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversion-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let previousTrace = "chunk=1 chars=4096 elapsed=12.4s\n"
        try Data(previousTrace.utf8).write(to: logURL)

        try RustConversionCoordinator().appendLogLine("[Rust] conversion resumed", to: logURL)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents, previousTrace + "[Rust] conversion resumed\n")
    }

    func testOptInImportedLordOfTheRingsConvertsAndPublishesPlayableAudio() async throws {
        let bookPath = ProcessInfo.processInfo.environment["EPUB2MP3_LOTR_IMPORTED_EPUB"]
        let resolvedBookPath = bookPath.flatMap { $0.contains("${") ? nil : $0 }
            ?? NSHomeDirectory() + "/Library/Application Support/EpubToMp3/ImportedBooks/3e1c676b270dfa3fe555eba4d0cb9934/The Lord of the Rings - en - J.R.R. Tolkien.epub"
        let bookURL = URL(fileURLWithPath: resolvedBookPath)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: bookURL.path), "Imported EPUB is not readable: \(bookURL.path)")

        let jobID = UUID().uuidString
        var publishedChapters: [JobSnapshot.Chapter] = []
        let adapter = ConverterFFIAdapter()
        let result = try await RustConversionCoordinator(adapter: adapter).convert(
            bookURL: bookURL,
            jobID: jobID,
            chapterStart: -1,
            chapterEnd: -1,
            onProgress: { event in
                _ = event
            },
            onChapterCompleted: { event in
                publishedChapters.append(event.playableChapter)
            }
        )

        let snapshot = try result.snapshot()
        XCTAssertGreaterThan(snapshot.chaptersTotal ?? 0, 1)
        XCTAssertEqual(snapshot.chaptersCompleted, snapshot.chaptersTotal)
        XCTAssertEqual(publishedChapters.count, snapshot.chaptersTotal)

        guard let firstAudioPath = snapshot.playableChapters.first?.downloadUrl else {
            return XCTFail("Rust returned no playable chapter audio.")
        }
        let firstAsset = AVURLAsset(url: URL(fileURLWithPath: firstAudioPath))
        let firstAudioIsPlayable = try await firstAsset.load(.isPlayable)
        XCTAssertTrue(firstAudioIsPlayable, "AVFoundation rejected the first Rust MP3.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudioPath))
    }

    func testOptInImportedLordOfTheRingsChapterNineConvertsAndPublishesPlayableAudio() async throws {
        let bookPath = ProcessInfo.processInfo.environment["EPUB2MP3_LOTR_IMPORTED_EPUB"]
        let resolvedBookPath = bookPath.flatMap { $0.contains("${") ? nil : $0 }
            ?? NSHomeDirectory() + "/Library/Application Support/EpubToMp3/ImportedBooks/3e1c676b270dfa3fe555eba4d0cb9934/The Lord of the Rings - en - J.R.R. Tolkien.epub"
        let bookURL = URL(fileURLWithPath: resolvedBookPath)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: bookURL.path))

        let jobID = UUID().uuidString
        var published: [JobSnapshot.Chapter] = []
        let adapter = ConverterFFIAdapter()
        let result = try await RustConversionCoordinator(adapter: adapter).convert(
            bookURL: bookURL,
            jobID: jobID,
            chapterStart: 8,
            chapterEnd: 8,
            onChapterCompleted: { event in published.append(event.playableChapter) }
        )

        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.chaptersTotal, 1)
        XCTAssertEqual(snapshot.chaptersCompleted, 1)
        XCTAssertEqual(published.count, 1)
        guard let path = snapshot.playableChapters.first?.downloadUrl else {
            return XCTFail("Chapter nine produced no playable audio.")
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
    }

    func testOptInTwoChaptersFromBothImportedBooksArePlayable() async throws {
        let applicationSupport = NSHomeDirectory() + "/Library/Application Support/EpubToMp3/ImportedBooks/"
        let cases: [(title: String, path: String, positions: ClosedRange<Int>)] = [
            (
                "The Lord of the Rings",
                applicationSupport + "3e1c676b270dfa3fe555eba4d0cb9934/The Lord of the Rings - en - J.R.R. Tolkien.epub",
                8...9
            ),
            (
                "E não sobrou nenhum",
                applicationSupport + "55417053355de78768a0823d3cd203fd/E não sobrou nenhum (Agatha Christie [Christie, Agatha]) (z-library.sk, 1lib.sk, z-lib.sk).epub",
                6...7
            ),
        ]

        for testCase in cases {
            let bookURL = URL(fileURLWithPath: testCase.path)
            XCTAssertTrue(
                FileManager.default.isReadableFile(atPath: bookURL.path),
                "Imported EPUB is not readable: \(bookURL.path)"
            )
            var published: [JobSnapshot.Chapter] = []
            let started = Date.timeIntervalSinceReferenceDate
            let result = try await RustConversionCoordinator().convert(
                bookURL: bookURL,
                jobID: UUID().uuidString,
                chapterStart: Int32(testCase.positions.lowerBound),
                chapterEnd: Int32(testCase.positions.upperBound),
                onChapterCompleted: { event in published.append(event.playableChapter) }
            )
            let elapsed = Date.timeIntervalSinceReferenceDate - started
            let snapshot = try result.snapshot()

            XCTAssertEqual(snapshot.chaptersTotal, 2, testCase.title)
            XCTAssertEqual(snapshot.chaptersCompleted, 2, testCase.title)
            XCTAssertEqual(published.count, 2, testCase.title)
            for chapter in snapshot.playableChapters {
                let audioPath = try XCTUnwrap(chapter.downloadUrl)
                let asset = AVURLAsset(url: URL(fileURLWithPath: audioPath))
                let isPlayable = try await asset.load(.isPlayable)
                XCTAssertTrue(isPlayable, "Invalid audio for \(testCase.title)")
            }
            print("[Rust Edge smoke] book=\(testCase.title) chapters=2 elapsed=\(elapsed)s")
        }
    }

    @MainActor
    func testStreamingIntentStartsWhenRustPublishesPlayableChapter() {
        let jobID = UUID().uuidString
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("stream-test.mp3")
        let player = AudioPlayer()
        let pending = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: "The Lord of the Rings",
            bookAuthor: "J.R.R. Tolkien", coverUrl: nil, coverMimeType: nil,
            engine: "edge", voice: nil, language: nil, progressPercent: 0,
            chaptersTotal: 1, chaptersCompleted: 0, chapterProgress: [],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        let chapter = JobSnapshot.Chapter(
            index: 0, name: "A Long-expected Party", status: "completed",
            downloadUrl: audioURL.path, chars: 8_000, charsProcessed: 8_000,
            progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil
        )
        player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
        player.isConverting = true
        player.resume()
        player.updateSnapshot(RustConversionCoordinator.ChapterCompletionEvent(
            jobId: jobID, bookTitle: "The Lord of the Rings", bookAuthor: "J.R.R. Tolkien",
            chapterIndex: 0, chaptersTotal: 1, chaptersCompleted: 1,
            chapterTitle: chapter.name ?? "A Long-expected Party", filename: "chapter.mp3", audioPath: audioURL,
            textChars: 8_000
        ).snapshot(chapters: [chapter]))
        XCTAssertTrue(player.isPlaying)
        player.stop()
    }

    func testRustProgressEventDecodesChapterActivityAndTerminalProgress() throws {
        let data = Data(
            #"{"jobId":"rust-job","state":"running","chapterIndex":4,"chaptersTotal":12,"chaptersCompleted":3,"percent":25.0,"engine":"edge","message":"converting chapter 5"}"#.utf8
        )

        let event = try JSONDecoder().decode(
            RustConversionCoordinator.ConversionProgressEvent.self,
            from: data
        )

        XCTAssertEqual(event.state, "running")
        XCTAssertEqual(event.chapterIndex, 4)
        XCTAssertEqual(event.chaptersCompleted, 3)
        XCTAssertEqual(event.chaptersTotal, 12)
        XCTAssertEqual(event.percent, 25)
        XCTAssertEqual(event.message, "converting chapter 5")
    }

    func testValidatedChapterEventMapsToPlayableLocalSnapshot() throws {
        let jobID = UUID().uuidString
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(jobID)-chapter.mp3")
        let payload: [String: Any] = [
            "jobId": jobID,
            "bookTitle": "The Lord of the Rings",
            "bookAuthor": "J.R.R. Tolkien",
            "chapterIndex": 7,
            "chaptersTotal": 24,
            "chaptersCompleted": 3,
            "chapterTitle": "A Long-expected Party",
            "filename": "0008-a-long-expected-party.mp3",
            "audioPath": audioURL.path,
            "textChars": 8_421,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try JSONDecoder().decode(
            RustConversionCoordinator.ChapterCompletionEvent.self,
            from: data
        )

        let chapter = event.playableChapter
        let snapshot = event.snapshot(chapters: [chapter])

        XCTAssertEqual(event.progressPercent, 12.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.jobId, jobID)
        XCTAssertEqual(snapshot.state, "running")
        XCTAssertEqual(snapshot.bookTitle, "The Lord of the Rings")
        XCTAssertNil(snapshot.engine, "A provider-neutral chapter event must not invent an Edge provider.")
        XCTAssertNil(snapshot.voice)
        XCTAssertNil(snapshot.language)
        XCTAssertEqual(snapshot.playableChapters.map(\.index), [7])
        XCTAssertEqual(snapshot.playableChapters.first?.downloadUrl, audioURL.path)
        XCTAssertEqual(snapshot.playableChapters.first?.name, "A Long-expected Party")
        XCTAssertEqual(snapshot.chaptersCompleted, 3)
        XCTAssertEqual(snapshot.chaptersTotal, 24)
    }

    func testChapterEventPreservesLiteralLocalAudioPath() throws {
        for filename in ["chapter #1?.mp3", "chapter %20 literal.mp3"] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(filename).path
            let payload: [String: Any] = [
                "jobId": "job", "bookTitle": "Book", "bookAuthor": "Author",
                "chapterIndex": 8, "chaptersTotal": 2, "chaptersCompleted": 1,
                "chapterTitle": "Chapter", "filename": filename,
                "audioPath": path, "textChars": 100,
            ]
            let event = try JSONDecoder().decode(RustConversionCoordinator.ChapterCompletionEvent.self,
                from: JSONSerialization.data(withJSONObject: payload))
            XCTAssertTrue(event.audioPath.isFileURL)
            XCTAssertEqual(event.audioPath.path, path)
            XCTAssertEqual(event.playableChapter.downloadUrl, path)
        }
        for path in ["chapter.mp3", "~/chapter.mp3", "https://example.invalid/chapter.mp3", "file:///tmp/chapter.mp3", "/tmp/chapter\0.mp3"] {
            let payload: [String: Any] = [
                "jobId": "job", "bookTitle": "Book", "bookAuthor": "Author",
                "chapterIndex": 8, "chaptersTotal": 2, "chaptersCompleted": 1,
                "chapterTitle": "Chapter", "filename": "chapter.mp3",
                "audioPath": path, "textChars": 100,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(try JSONDecoder().decode(RustConversionCoordinator.ChapterCompletionEvent.self, from: data))
        }
    }

    func testOptInRealEdgeBenchmarkComparesSerialAndTwoChapterWorkers() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_RUN_REAL_EDGE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set EPUB2MP3_RUN_REAL_EDGE_BENCHMARK=1 to run the network benchmark.")
        }
        let bookPath = NSHomeDirectory()
            + "/Library/Application Support/EpubToMp3/ImportedBooks/3e1c676b270dfa3fe555eba4d0cb9934/The Lord of the Rings - en - J.R.R. Tolkien.epub"
        let bookURL = URL(fileURLWithPath: bookPath)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: bookURL.path))

        let previousParallelism = getenv("RUST_CHAPTER_PARALLELISM").map { String(cString: $0) }
        defer {
            if let previousParallelism {
                setenv("RUST_CHAPTER_PARALLELISM", previousParallelism, 1)
            } else {
                unsetenv("RUST_CHAPTER_PARALLELISM")
            }
        }

        func convert(parallelism: String) async throws -> (TimeInterval, RustConversionCoordinator.Result) {
            XCTAssertEqual(setenv("RUST_CHAPTER_PARALLELISM", parallelism, 1), 0)
            let started = Date.timeIntervalSinceReferenceDate
            let result = try await RustConversionCoordinator().convert(
                bookURL: bookURL,
                jobID: UUID().uuidString,
                chapterStart: 8,
                chapterEnd: 9
            )
            return (Date.timeIntervalSinceReferenceDate - started, result)
        }

        let (serialSeconds, serialResult) = try await convert(parallelism: "1")
        let (parallelSeconds, parallelResult) = try await convert(parallelism: "2")
        for result in [serialResult, parallelResult] {
            let snapshot = try result.snapshot()
            XCTAssertEqual(snapshot.chaptersCompleted, 2)
            XCTAssertEqual(snapshot.playableChapters.count, 2)
            for chapter in snapshot.playableChapters {
                let audioPath = try XCTUnwrap(chapter.downloadUrl)
                let asset = AVURLAsset(url: URL(fileURLWithPath: audioPath))
                let playable = try await asset.load(.isPlayable)
                XCTAssertTrue(playable)
            }
        }
        let speedup = serialSeconds / max(parallelSeconds, 0.001)
        print("[Rust Edge benchmark] serial=\(serialSeconds)s parallel2=\(parallelSeconds)s speedup=\(speedup)x")
    }
}
