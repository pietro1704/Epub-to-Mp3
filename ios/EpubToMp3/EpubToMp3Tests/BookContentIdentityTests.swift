import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class BookContentIdentityTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testStableIdentityUsesContentAndPreservesExistingHashFormat() throws {
        let root = try fixture()
        let first = root.appendingPathComponent("first.epub")
        let second = root.appendingPathComponent("renamed.epub")
        try Data("abc".utf8).write(to: first)
        try FileManager.default.copyItem(at: first, to: second)
        XCTAssertEqual(try BookContentIdentity.hash(of: first), "ba7816bf8f01cfea414140de5dae2223")
        XCTAssertEqual(try BookContentIdentity.hash(of: first), try BookContentIdentity.hash(of: second))
        try Data("changed".utf8).write(to: second)
        XCTAssertNotEqual(try BookContentIdentity.hash(of: first), try BookContentIdentity.hash(of: second))
        XCTAssertThrowsError(try BookContentIdentity.hash(of: root.appendingPathComponent("missing")))
    }

    func testOutputOwnershipUsesTheSameRealBookIdentity() async throws {
        let root = try fixture()
        let book = root.appendingPathComponent("book.epub")
        try Data("abc".utf8).write(to: book)
        let store = RustConversionOutputStore(root: root.appendingPathComponent("outputs"))
        let lease = try await store.begin(bookURL: book, jobID: "job", cancel: {})
        let audio = lease.outputDirectory.appendingPathComponent("audio.mp3")
        try Data([1, 2, 3]).write(to: audio)
        await store.finish(lease)
        try await store.removeAudio(bookID: "other-book", legacyJobID: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        try await store.removeAudio(bookID: BookContentIdentity.hash(of: book), legacyJobID: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(try Data(contentsOf: book), Data("abc".utf8))
    }

    func testCancelledIdentityLookupCannotCreateOutputDirectory() async throws {
        let root = try fixture().appendingPathComponent("outputs")
        let store = RustConversionOutputStore(root: root, bookIdentity: { _ in
            throw CancellationError()
        })
        do {
            _ = try await store.begin(bookURL: root, jobID: "cancelled", cancel: {})
            XCTFail("Cancelled lookup must not reserve output storage")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }
}
