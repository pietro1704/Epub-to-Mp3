import Foundation
import XCTest
@testable import EpubToMp3

final class LocalAudiobookArchiveExporterTests: XCTestCase {
    func testExportsCompletedChaptersAndPartialManifestInOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audiobook-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let second = root.appendingPathComponent("second.mp3")
        let fifth = root.appendingPathComponent("fifth.mp3")
        try Data([2, 2, 2]).write(to: second)
        try Data([5, 5, 5]).write(to: fifth)

        let archive = try LocalAudiobookArchiveExporter.export(
            bookID: "book-id",
            bookTitle: "Book",
            author: "Author",
            chapters: [
                .init(index: 4, title: "Five", fileURL: fifth),
                .init(index: 1, title: "Two", fileURL: second),
                .init(
                    index: 8,
                    title: "Missing",
                    fileURL: root.appendingPathComponent("missing.mp3"),
                    availability: .failed,
                    lastError: "Network unavailable"
                )
            ],
            destinationDirectory: root
        )

        XCTAssertEqual(ZipReader.listEntries(in: archive), ["002 - Two.mp3", "005 - Five.mp3", "manifest.json"])
        let manifestData = try XCTUnwrap(ZipReader.extract(member: "manifest.json", from: archive))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        XCTAssertEqual(manifest?["isPartial"] as? Bool, true)
        XCTAssertEqual((manifest?["chapters"] as? [[String: Any]])?.map { $0["index"] as? Int }, [1, 4])
        let missing = manifest?["missingChapters"] as? [[String: Any]]
        XCTAssertEqual(missing?.map { $0["index"] as? Int }, [8])
        XCTAssertEqual(missing?.first?["state"] as? String, "failed")
        XCTAssertEqual(missing?.first?["error"] as? String, "Network unavailable")
    }
}
