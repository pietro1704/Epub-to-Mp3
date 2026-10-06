import Foundation
import XCTest
@testable import EpubToMp3

final class DownloadManagerBackgroundTests: XCTestCase {
    func testBackgroundConfigurationUsesStableIdentifierAndDiscretionaryOff() {
        let configuration = DownloadManager.backgroundSessionConfiguration()

        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
#if os(iOS)
        XCTAssertEqual(configuration.identifier, DownloadManager.backgroundSessionIdentifier)
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

        XCTAssertThrowsError(try DownloadManager.commitDownloadedFile(
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

        let bytes = try DownloadManager.commitDownloadedFile(
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
        XCTAssertEqual(DownloadManager.resolve(path: source.absoluteString, base: nil), source)
    }

    func testResumeRequestUsesInclusiveByteRange() {
        let url = URL(string: "https://example.com/chapter.mp3")!
        let request = DownloadManager.request(url: url, resumingAt: 128)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=128-")
    }

    func testResumeRequestOmitsRangeForFreshDownload() {
        let url = URL(string: "https://example.com/chapter.mp3")!
        let request = DownloadManager.request(url: url, resumingAt: 0)

        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
    }

    func testContentRangeReportsCompleteObjectSize() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/chapter.mp3")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 128-255/256"]
        )!

        XCTAssertEqual(DownloadManager.contentRangeTotal(from: response), 256)
    }

    func testWildcardContentRangeDoesNotValidateAResumedObject() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/chapter.mp3")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["Content-Range": "bytes 128-255/*"]
        )!

        XCTAssertNil(DownloadManager.contentRangeTotal(from: response))
    }

    func testLocalFixtureDownloadsAllChaptersAndRoutesPlaybackOffline() async throws {
        let jobId = "download-fixture-\(UUID().uuidString)"
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        defer {
            DownloadManager.deleteAudiobook(jobId: jobId)
            try? FileManager.default.removeItem(at: sourceRoot)
        }

        let chapterOne = sourceRoot.appendingPathComponent("chapter-one.mp3")
        let chapterFive = sourceRoot.appendingPathComponent("chapter-five.mp3")
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
        let manager = DownloadManager()
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
        XCTAssertEqual(DownloadManager.locallyDownloadedIndices(for: jobId), [0, 4])
        XCTAssertTrue(DownloadManager.isManifestComplete(
            DownloadManager.loadManifest(for: jobId)!,
            expectedChapterIndices: [0, 4]
        ))

        let restored = try XCTUnwrap(DownloadManager.localPlaybackSnapshot(jobId: jobId))
        XCTAssertEqual(restored.state, "finished")
        XCTAssertEqual(restored.playableChapters.map(\.index), [0, 4])
        XCTAssertTrue(restored.playableChapters.allSatisfy { $0.downloadUrl?.hasPrefix("file:") == true })

        let localURL = try XCTUnwrap(DownloadManager.localAudioURL(jobId: jobId, chapterIndex: 4))
        let route = PlaybackRouter.route(
            chapter: snapshot.playableChapters[1],
            baseURL: nil,
            localAudioURL: localURL,
            chapterText: nil,
            languageCode: nil,
            isAudioPlayable: { url in
                guard url.isFileURL else { return false }
                return (try? Data(contentsOf: url).isEmpty) == false
            }
        )

        XCTAssertEqual(route, .audio(localURL))
    }
}
