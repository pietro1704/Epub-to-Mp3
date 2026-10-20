import Foundation
import XCTest
@testable import EpubToMp3

final class RustOutputRootValidationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RustOutputRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSystemTemporaryRootSupportsWritingCountingAndOwnedRemoval() async throws {
        let root = try fixture()
        let store = RustConversionOutputStore(root: root)
        let lease = try await store.begin(bookID: "book", jobID: "job", cancel: {})
        let audio = lease.outputDirectory.appendingPathComponent("chapter.mp3")
        try Data([1, 2, 3]).write(to: audio)
        await store.finish(lease)
        XCTAssertGreaterThanOrEqual(RustConversionOutputStore.storageBytes(at: root), 3)
        try await store.removeAudio(bookID: "book")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testCustomSymlinkAncestorStillRejectsWritesAndRemoval() async throws {
        let root = try fixture()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let audio = outside.appendingPathComponent("keep.mp3")
        try Data([7, 8]).write(to: audio)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        let outputs = alias.appendingPathComponent("outputs", isDirectory: true)
        let store = RustConversionOutputStore(root: outputs)
        do {
            _ = try await store.begin(bookID: "book", jobID: "job", cancel: {})
            XCTFail("A custom symlink ancestor must not authorize writes")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadInvalidFileName.rawValue)
        }
        XCTAssertEqual(RustConversionOutputStore.storageBytes(at: outputs), 0)
        do {
            try await store.clearAllAudio()
            XCTFail("A custom symlink ancestor must not authorize removal")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadInvalidFileName.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: audio), Data([7, 8]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("outputs").path))
    }

    func testCanonicalRootStillRejectsTraversalAndPreservesAnotherBooksOutput() async throws {
        let root = try fixture()
        let store = RustConversionOutputStore(root: root)
        let other = try await store.begin(bookID: "other-book", jobID: "other-job", cancel: {})
        let audio = other.outputDirectory.appendingPathComponent("chapter.mp3")
        try Data([9]).write(to: audio)
        await store.finish(other)
        for job in ["../outside", "nested/job", ".hidden", ""] {
            do {
                _ = try await store.begin(bookID: "book", jobID: job, cancel: {})
                XCTFail("Invalid job identifiers must remain rejected")
            } catch {
                XCTAssertEqual((error as NSError).code, CocoaError.fileWriteInvalidFileName.rawValue)
            }
        }
        try await store.removeAudio(bookID: "book")
        XCTAssertEqual(try Data(contentsOf: audio), Data([9]))
    }
}
