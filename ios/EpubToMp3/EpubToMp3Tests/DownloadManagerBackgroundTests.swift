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
}
