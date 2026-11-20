import Foundation
import XCTest
@testable import EpubToMp3

final class DownloadManagerBackgroundTests: XCTestCase {
    func testBackgroundConfigurationUsesStableIdentifierAndDiscretionaryOff() {
        let configuration = AudiobookDownloads.backgroundSessionConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
#if os(iOS)
        XCTAssertEqual(configuration.identifier, AudiobookDownloads.backgroundSessionIdentifier)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
#else
        // Host tests run on macOS, where URLSession background sessions are
        // unavailable; the iOS-specific assertions are covered by the build.
        XCTAssertNil(configuration.identifier)
#endif
    }

    func testInterruptedPartialArtifactIsNotInstalledAsCompleteFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("chapter.mp3")
        let partial = root.appendingPathComponent("chapter.mp3.partial")
        try Data("partial".utf8).write(to: partial)

        XCTAssertThrowsError(try AudiobookChapterTransfer.commitDownloadedFile(
            from: partial,
            to: destination,
            expectedBytes: 100
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    }

    func testCompleteArtifactIsAtomicallyMovedToDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root.appendingPathComponent("chapter.mp3")
        let staged = root.appendingPathComponent("chapter.mp3.partial")
        try Data(repeating: 0x01, count: 8).write(to: staged)

        let bytes = try AudiobookChapterTransfer.commitDownloadedFile(
            from: staged,
            to: destination,
            expectedBytes: 8
        )

        XCTAssertEqual(bytes, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testLocalFileURLsAreValidDownloadSources() {
        let source = URL(fileURLWithPath: "/tmp/chapter.mp3")
        XCTAssertEqual(AudiobookChapterTransfer.resolve(path: source.absoluteString, base: nil), source)
    }

    func testNativeAbsolutePathsPreserveLiteralFilenameCharacters() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("chapter #1? 100%.mp3")
        let bytes = Data([0xFF, 0xFB, 0x90, 0x00])
        try bytes.write(to: source)

        let resolved = try XCTUnwrap(AudiobookChapterTransfer.resolve(path: source.path, base: nil))

        XCTAssertTrue(resolved.isFileURL)
        XCTAssertEqual(resolved.path, source.path)
        XCTAssertEqual(try Data(contentsOf: resolved), bytes)
        let fileBase = root.appendingPathComponent("outputs", isDirectory: true)
        let resolvedAgainstLocalBase = try XCTUnwrap(AudiobookChapterTransfer.resolve(path: source.path, base: fileBase))
        XCTAssertEqual(resolvedAgainstLocalBase, source)
        XCTAssertEqual(try Data(contentsOf: resolvedAgainstLocalBase), bytes)
    }

    func testRemotePathsContinueToResolveAgainstTheirServerBase() throws {
        let base = try XCTUnwrap(URL(string: "https://example.com/jobs/"))
        XCTAssertEqual(AudiobookChapterTransfer.resolve(path: "chapter.mp3", base: base)?.absoluteString,
                       "https://example.com/jobs/chapter.mp3")
        XCTAssertEqual(AudiobookChapterTransfer.resolve(path: "/audio/chapter.mp3", base: base)?.absoluteString,
                       "https://example.com/audio/chapter.mp3")
        XCTAssertEqual(AudiobookChapterTransfer.resolve(path: "https://other.example/chapter.mp3", base: nil)?.absoluteString,
                       "https://other.example/chapter.mp3")
        XCTAssertNil(AudiobookChapterTransfer.resolve(path: "chapter.mp3", base: nil))
    }

    func testResumeRequestUsesInclusiveByteRange() {
        let url = URL(string: "https://example.com/chapter.mp3")!
        let request = AudiobookChapterTransfer.request(url: url, resumingAt: 128)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=128-")
    }

    func testResumeRequestOmitsRangeForFreshDownload() {
        let url = URL(string: "https://example.com/chapter.mp3")!
        let request = AudiobookChapterTransfer.request(url: url, resumingAt: 0)

        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
    }

    func testContentRangeReportsCompleteObjectSize() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/chapter.mp3")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 128-255/256"]
        )!

        XCTAssertEqual(AudiobookChapterTransfer.contentRangeTotal(from: response), 256)
    }

    func testWildcardContentRangeDoesNotValidateAResumedObject() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/chapter.mp3")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 128-255/*"]
        )!

        XCTAssertNil(AudiobookChapterTransfer.contentRangeTotal(from: response))
    }

    func testLocalFixtureKeepsAllChaptersInTheBookStoreAndRestoresThemOffline() async throws {
        let jobId = "download-fixture-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = AudiobookDownloadStorage.rootOverrideForTesting
        AudiobookDownloadStorage.rootOverrideForTesting = root.appendingPathComponent("previous-layout")
        defer {
            AudiobookDownloadStorage.rootOverrideForTesting = previousRoot
            try? FileManager.default.removeItem(at: root)
        }

        let chapterOne = root.appendingPathComponent("chapter-one.mp3")
        let chapterFive = root.appendingPathComponent("chapter-five.mp3")
        try Data(repeating: 0x11, count: 32).write(to: chapterOne)
        try Data(repeating: 0x22, count: 48).write(to: chapterFive)

        let snapshotJSON = """
        {
          "jobId": "\(jobId)",
          "state": "finished",
          "bookTitle": "Offline fixture",
          "chapterProgress": [
            {"index": 0, "name": "Chapter One", "status": "completed", "downloadUrl": "\(chapterOne.absoluteString)"},
            {"index": 4, "name": "Chapter Five", "status": "completed", "downloadUrl": "\(chapterFive.absoluteString)"}
          ]
        }
        """
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data(snapshotJSON.utf8))
        let store = LocalAudioArtifactStore(root: root.appendingPathComponent("artifacts"))
        let manager = LegacyAudiobookFixture.downloads(store: store)
        let progress = await manager.watchProgress(jobId: jobId)

        await manager.enqueueAll(snapshot: snapshot, baseURL: nil)

        var terminalProgress: DownloadProgress?
        for await update in progress {
            if update.state == .completed || update.state == .failed {
                terminalProgress = update
                break
            }
        }

        XCTAssertEqual(terminalProgress?.state, .completed)
        XCTAssertEqual(terminalProgress?.completedChapters, 2)
        let kept = await manager.downloadedIndices(for: snapshot)
        XCTAssertEqual(kept, [0, 4])
        XCTAssertNil(AudiobookDownloadStorage.loadManifest(for: jobId),
                     "A Download must not write the previous layout")
        XCTAssertEqual(try Data(contentsOf: chapterFive), Data(repeating: 0x22, count: 48),
                       "The converted source is only read")

        let restoredSnapshot = try await store.playableSnapshot(
            bookID: jobId, engine: "piper", voice: "auto", language: nil)
        let restored = try XCTUnwrap(restoredSnapshot)
        XCTAssertEqual(restored.bookTitle, "Offline fixture")
        XCTAssertEqual(restored.playableChapters.map(\.index), [0, 4])
        XCTAssertEqual(restored.playableChapters.map(\.name), ["Chapter One", "Chapter Five"])
        let localURL = try XCTUnwrap(restored.playableChapters[1].downloadUrl.flatMap(URL.init(string:)))
        XCTAssertEqual(try Data(contentsOf: localURL), Data(repeating: 0x22, count: 48))
    }

    func testDownloadOfASnapshotWithoutAKnownBookFailsWithoutWritingAnything() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-unowned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = AudiobookDownloadStorage.rootOverrideForTesting
        AudiobookDownloadStorage.rootOverrideForTesting = root.appendingPathComponent("previous-layout")
        defer {
            AudiobookDownloadStorage.rootOverrideForTesting = previousRoot
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("chapter.mp3")
        try Data(repeating: 0x33, count: 16).write(to: source)
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "jobId": "unowned", "state": "finished", "bookTitle": "Unowned",
            "chapterProgress": [["index": 0, "name": "Chapter", "status": "completed",
                                 "downloadUrl": source.absoluteString]]
        ]))
        let artifacts = root.appendingPathComponent("artifacts")
        let manager = AudiobookDownloads(store: LocalAudioArtifactStore(root: artifacts),
                                         resolveOwner: { _ in nil }, stopLegacyMigration: {})
        let progress = await manager.watchProgress(jobId: "unowned")
        await manager.enqueueAll(snapshot: snapshot, baseURL: nil)
        var terminal: DownloadProgress?
        for await update in progress where update.state == .completed || update.state == .failed {
            terminal = update
            break
        }
        XCTAssertEqual(terminal?.state, .failed)
        XCTAssertEqual(terminal?.completedChapters, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifacts.path))
        XCTAssertNil(AudiobookDownloadStorage.loadManifest(for: "unowned"))
    }
    func testRemovingDownloadsStopsTheMigrationAndNeverTakesTheOnlyAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousRoot = AudiobookDownloadStorage.rootOverrideForTesting
        AudiobookDownloadStorage.rootOverrideForTesting = root.appendingPathComponent("previous-layout")
        defer {
            AudiobookDownloadStorage.rootOverrideForTesting = previousRoot
            try? FileManager.default.removeItem(at: root)
        }
        let artifacts = root.appendingPathComponent("artifacts")
        let audio = Data(repeating: 8, count: 32)
        // Chapter 0 and 1 are kept copies of converted files, chapter 2 plays
        // from the store itself, chapter 7 belongs to an earlier conversion.
        let kept = try LocalAudioArtifactFixture.seed(root: artifacts, bookID: "book", chapters: [
            .init(index: 0, title: "Zero", retention: .downloaded, audio: audio),
            .init(index: 1, title: "One", retention: .downloaded, audio: audio),
            .init(index: 2, title: "Two", retention: .downloaded, audio: audio),
            .init(index: 7, title: "Seven", retention: .downloaded, audio: audio)
        ])
        var chapters: [[String: Any]] = []
        for index in [0, 1] {
            let converted = root.appendingPathComponent("converted-\(index).mp3")
            try audio.write(to: converted)
            chapters.append(["index": index, "name": "Chapter", "status": "completed", "downloadUrl": converted.path])
        }
        chapters.append(["index": 2, "name": "Chapter", "status": "completed",
                         "downloadUrl": try XCTUnwrap(kept[2]).absoluteString])
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "jobId": "job", "state": "finished", "bookTitle": "Book", "chapterProgress": chapters
        ]))
        let stops = StopCounter()
        let store = LocalAudioArtifactStore(root: artifacts)
        let manager = AudiobookDownloads(
            store: store, resolveOwner: { _ in RetainedAudioOwner(bookID: "book", indexBase: 0) },
            stopLegacyMigration: { await stops.add() })

        var badges = await manager.downloadedIndices(for: snapshot)
        XCTAssertEqual(badges, [0, 1, 2, 7])
        await manager.removeDownload(snapshot: snapshot, chapterIndex: 0)
        var stopped = await stops.value
        XCTAssertEqual(stopped, 1, "A removal stops the migration first")
        var remaining = try await store.downloadedChapterIndices(bookID: "book")
        XCTAssertEqual(remaining, [1, 2, 7])
        // The chapter that plays from the store keeps its only audio.
        await manager.removeDownload(snapshot: snapshot, chapterIndex: 2)
        remaining = try await store.downloadedChapterIndices(bookID: "book")
        XCTAssertEqual(remaining, [1, 2, 7])

        await manager.clearDownloads(snapshot: snapshot)
        stopped = await stops.value
        XCTAssertEqual(stopped, 3)
        remaining = try await store.downloadedChapterIndices(bookID: "book")
        XCTAssertEqual(remaining, [2, 7], "Audio with no other source and audio of another conversion stay")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept[2])), audio)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(kept[7])), audio)
        badges = await manager.downloadedIndices(for: snapshot)
        XCTAssertEqual(badges, [2, 7])
    }
}

private actor StopCounter {
    private(set) var value = 0
    func add() { value += 1 }
}
