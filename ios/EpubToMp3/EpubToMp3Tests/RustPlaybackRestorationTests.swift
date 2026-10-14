import XCTest
@testable import EpubToMp3

final class RustPlaybackRestorationTests: XCTestCase {
    func testPartialDownloadKeepsOtherConvertedChaptersAndPrefersRetainedFile() throws {
        try withFixture { job, manager, directory in
            let retained = DownloadManager.audiobookFolder(for: job).appendingPathComponent("retained.mp3")
            try Data([1, 2, 3]).write(to: retained)
            try DownloadManager.saveManifest(.init(jobId: job, bookTitle: "Retained",
                chapters: [.init(index: 0, title: "Retained title", mp3FileName: "retained.mp3",
                                 mp3Bytes: 3, downloadedAt: Date())], totalBytes: 3, completedAt: nil))
            let source = try XCTUnwrap(RustConversionCoordinator.persistedSnapshot(jobID: job, fileManager: manager))
            let merged = try XCTUnwrap(DownloadManager.restoredPlaybackSnapshot(jobId: job, conversionSnapshot: source))
            XCTAssertEqual(merged.playableChapters.map(\.index), [0, 1])
            XCTAssertEqual(merged.playableChapters[0].downloadUrl, retained.absoluteString)
            XCTAssertEqual(merged.playableChapters[0].name, "Chapter zero")
            XCTAssertEqual(merged.playableChapters[0].chars, 100)
            XCTAssertEqual(merged.playableChapters[1].downloadUrl, directory.appendingPathComponent("one.mp3").path)

            try FileManager.default.removeItem(at: directory.appendingPathComponent("one.mp3"))
            let missing = RustConversionCoordinator.persistedSnapshot(jobID: job, fileManager: manager)
            XCTAssertNil(missing)
            XCTAssertEqual(DownloadManager.restoredPlaybackSnapshot(jobId: job, conversionSnapshot: missing)?.playableChapters.map(\.index), [0])
        }
    }

    func testInvalidMissingAndUnsafePersistedArtifactsAreRejected() throws {
        try withFixture { job, manager, directory in
            XCTAssertNil(RustConversionCoordinator.persistedSnapshot(jobID: "../escape", fileManager: manager))
            XCTAssertNil(RustConversionCoordinator.persistedSnapshot(jobID: "", fileManager: manager))
            XCTAssertNil(RustConversionCoordinator.persistedSnapshot(jobID: "missing", fileManager: manager))
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let original = try Data(contentsOf: manifestURL)
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            manifest["jobId"] = "other-job"
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            XCTAssertNil(RustConversionCoordinator.persistedSnapshot(jobID: job, fileManager: manager))
            manifest["jobId"] = job
            manifest["chapters"] = [["title": "Escape", "filename": "../outside.mp3", "textChars": 1, "sourceIndex": 0]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            XCTAssertNil(RustConversionCoordinator.persistedSnapshot(jobID: job, fileManager: manager))
            try Data("invalid".utf8).write(to: manifestURL)
            XCTAssertNil(RustConversionCoordinator.persistedSnapshot(jobID: job, fileManager: manager))
            try original.write(to: manifestURL)
            try Data().write(to: directory.appendingPathComponent("zero.mp3"))
            XCTAssertNil(RustConversionCoordinator.persistedSnapshot(jobID: job, fileManager: manager))
        }
    }

    private func withFixture(_ body: (String, FileManager, URL) throws -> Void) throws {
        let job = "restore-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(job)
        let directory = root.appendingPathComponent("EpubToMp3/RustConversions/\(job)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            DownloadManager.deleteAudiobook(jobId: job)
            try? FileManager.default.removeItem(at: root)
        }
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("zero.mp3"))
        try Data([4, 5, 6]).write(to: directory.appendingPathComponent("one.mp3"))
        let manifest: [String: Any] = ["jobId": job, "title": "Converted", "author": "Author",
            "chapters": [["title": "Chapter zero", "filename": "zero.mp3", "textChars": 100, "sourceIndex": 0],
                         ["title": "Chapter one", "filename": "one.mp3", "textChars": 200, "sourceIndex": 1]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try body(job, RestorationFileManager(root: root), directory)
    }
}

private final class RestorationFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL { root }
}
