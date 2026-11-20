import Foundation
import XCTest
@testable import EpubToMp3

/// Which file a chapter plays from. The fixtures are not MP3, so no audio
/// preparation runs; only the choice of file is under test.
final class PlaybackArtifactLocationTests: XCTestCase {
    private var root: URL!
    private var previousRoot: URL?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackArtifactLocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        previousRoot = AudiobookDownloadStorage.rootOverrideForTesting
        AudiobookDownloadStorage.rootOverrideForTesting = root.appendingPathComponent("Audiobooks")
    }

    override func tearDownWithError() throws {
        AudiobookDownloadStorage.rootOverrideForTesting = previousRoot
        try? FileManager.default.removeItem(at: root)
    }

    private func keepLegacyCopy(job: String, chapter: Int) throws -> URL {
        let copy = try XCTUnwrap(AudiobookDownloadStorage.audiobookFolder(for: job)).appendingPathComponent("kept.wav")
        try Data([9, 9]).write(to: copy)
        try LegacyAudiobookFixture.save(.init(jobId: job, bookTitle: "Book",
            chapters: [.init(index: chapter, title: "Kept", mp3FileName: "kept.wav", mp3Bytes: 2, downloadedAt: Date())],
            totalBytes: 2, completedAt: nil))
        return copy
    }

    func testAChapterPlaysFromItsOwnFileEvenWhenACopyIsKept() throws {
        let own = root.appendingPathComponent("converted.wav")
        try Data([1]).write(to: own)
        _ = try keepLegacyCopy(job: "job", chapter: 3)
        let resolved = PlaybackArtifactLocation.resolve(
            forDownloadPath: own.path, jobId: "job", chapterIndex: 3, backendBaseURL: nil)
        XCTAssertEqual(resolved?.standardizedFileURL.path, own.standardizedFileURL.path)
    }

    func testTheKeptCopyStandsInWhenTheChaptersOwnFileIsGone() throws {
        let missing = root.appendingPathComponent("gone.wav")
        let copy = try keepLegacyCopy(job: "job", chapter: 3)
        let resolved = PlaybackArtifactLocation.resolve(
            forDownloadPath: missing.path, jobId: "job", chapterIndex: 3, backendBaseURL: nil)
        XCTAssertEqual(resolved?.resolvingSymlinksInPath().path, copy.resolvingSymlinksInPath().path)
        XCTAssertNil(PlaybackArtifactLocation.resolve(
            forDownloadPath: missing.path, jobId: "job", chapterIndex: 4, backendBaseURL: nil),
            "A missing local file with no kept copy has nothing to play")
    }

    func testARemoteChapterPrefersItsKeptCopyAndOtherwiseStaysRemote() throws {
        let copy = try keepLegacyCopy(job: "job", chapter: 0)
        let remote = "https://example.invalid/chapter.mp3"
        let kept = PlaybackArtifactLocation.resolve(
            forDownloadPath: remote, jobId: "job", chapterIndex: 0, backendBaseURL: nil)
        XCTAssertEqual(kept?.resolvingSymlinksInPath().path, copy.resolvingSymlinksInPath().path)
        let streamed = PlaybackArtifactLocation.resolve(
            forDownloadPath: remote, jobId: "job", chapterIndex: 1, backendBaseURL: nil)
        XCTAssertEqual(streamed?.absoluteString, remote)
    }
    func testTheKeptCopyStandsInWhenTheChaptersOwnFileCannotBePrepared() throws {
        // An MP3 that cannot be prepared for playback: the same test the
        // migration applies before it lets go of a kept copy.
        let own = root.appendingPathComponent("broken.mp3")
        try Data("not an mp3".utf8).write(to: own)
        XCTAssertFalse(PlaybackArtifactLocation.isPlayable(own))
        let copy = try keepLegacyCopy(job: "job", chapter: 3)
        let resolved = PlaybackArtifactLocation.resolve(
            forDownloadPath: own.path, jobId: "job", chapterIndex: 3, backendBaseURL: nil)
        XCTAssertEqual(resolved?.resolvingSymlinksInPath().path, copy.resolvingSymlinksInPath().path)
        XCTAssertTrue(PlaybackArtifactLocation.isPlayable(copy))
        XCTAssertFalse(PlaybackArtifactLocation.isPlayable(root.appendingPathComponent("absent.wav")))
    }
}
