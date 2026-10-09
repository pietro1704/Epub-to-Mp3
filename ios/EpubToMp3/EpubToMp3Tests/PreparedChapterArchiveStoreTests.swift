import CryptoKit
import Foundation
import XCTest
@testable import EpubToMp3

private final class PreparedArchiveIOProbe: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    var mainThreadObservations: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return threads
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock(); threads.append(Thread.isMainThread); lock.unlock()
        return try super.attributesOfItem(atPath: path)
    }
}

final class PreparedChapterArchiveStoreTests: XCTestCase {
    private var root: URL!
    private let signature = String(repeating: "a", count: 64)
    private let bytes = Data("Opaque immutable archive bytes".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prepared-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func target(_ bookID: String = "book", chapter: Int = 0) -> URL {
        let hash = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(hash)-\(chapter).archive")
    }

    func testMissingRootIsCreatedAndReplacementSurvivesReopen() async throws {
        let directory = root.appendingPathComponent("new-store", isDirectory: true)
        let store = PreparedChapterArchiveStore(directory: directory)
        let missing = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertNil(missing)
        try await store.write(bytes, bookID: "book", chapterIndex: 0, signature: signature)
        let replacement = Data("New prepared archive".utf8)
        try await store.write(replacement, bookID: "book", chapterIndex: 0, signature: signature)
        let reopened = PreparedChapterArchiveStore(directory: directory)
        let value = await reopened.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertEqual(value, replacement)
    }

    func testArchiveSurvivesNewInstanceAndBookScopedRemoval() async throws {
        let bookID = "../../outside/book"
        let store = PreparedChapterArchiveStore(directory: root)
        try await store.write(bytes, bookID: bookID, chapterIndex: 0, signature: signature)
        try await store.write(bytes, bookID: "other", chapterIndex: 0, signature: signature)
        try await store.write(bytes, bookID: bookID, chapterIndex: 1, signature: signature)
        let reopened = PreparedChapterArchiveStore(directory: root)
        let restored = await reopened.read(bookID: bookID, chapterIndex: 0, signature: signature)
        XCTAssertEqual(restored, bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target(bookID).path))
        try await reopened.remove(bookID: bookID, chapterIndex: 0)
        let removed = await reopened.read(bookID: bookID, chapterIndex: 0, signature: signature)
        let other = await reopened.read(bookID: "other", chapterIndex: 0, signature: signature)
        let chapter = await reopened.read(bookID: bookID, chapterIndex: 1, signature: signature)
        XCTAssertNil(removed)
        XCTAssertEqual(other, bytes)
        XCTAssertEqual(chapter, bytes)
    }

    func testSettingsSourceChapterAndEnvelopeMismatchesAreCacheMisses() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        try await store.write(bytes, bookID: "book", chapterIndex: 0, signature: signature)
        // The caller's signature incorporates source and presentation settings.
        for changedSignature in [String(repeating: "b", count: 64), String(repeating: "c", count: 64)] {
            let value = await store.read(bookID: "book", chapterIndex: 0, signature: changedSignature)
            XCTAssertNil(value)
        }
        try FileManager.default.copyItem(at: target(), to: target(chapter: 1))
        let wrongChapter = await store.read(bookID: "book", chapterIndex: 1, signature: signature)
        XCTAssertNil(wrongChapter)
        try FileManager.default.copyItem(at: target(), to: target("other"))
        let wrongBook = await store.read(bookID: "other", chapterIndex: 0, signature: signature)
        XCTAssertNil(wrongBook)
        let envelope: [String: Any] = ["schema": 999, "bookID": "book", "chapterIndex": 0,
                                       "signature": signature, "archive": bytes,
                                       "checksum": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0)
            .write(to: target())
        let wrongSchema = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertNil(wrongSchema)
    }

    func testCorruptAndOversizedFilesAreMissesAndOversizedWritesPreservePrior() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        try await store.write(bytes, bookID: "book", chapterIndex: 0, signature: signature)
        let committed = try Data(contentsOf: target())
        do {
            try await store.write(Data(count: PreparedChapterArchiveStore.maximumFileBytes + 1),
                                  bookID: "book", chapterIndex: 0, signature: signature)
            XCTFail("Oversized archive must be rejected")
        } catch { XCTAssertEqual(try Data(contentsOf: target()), committed) }
        try Data("Corrupt envelope".utf8).write(to: target())
        let corrupt = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertNil(corrupt)
        try Data(count: PreparedChapterArchiveStore.maximumFileBytes + 1).write(to: target())
        let oversized = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertNil(oversized)
    }

    func testWellFormedEnvelopeWithChangedArchiveIsACacheMiss() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        try await store.write(bytes, bookID: "book", chapterIndex: 0, signature: signature)
        var envelope = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: target()), format: nil) as? [String: Any])
        envelope["archive"] = Data("Changed but structurally valid archive".utf8)
        try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0).write(to: target())
        let value = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertNil(value)
    }

    func testBudgetFailurePreservesAllCommittedCaches() async throws {
        let store = PreparedChapterArchiveStore(directory: root)
        try await store.write(bytes, bookID: "book", chapterIndex: 0, signature: signature)
        let committed = try Data(contentsOf: target())
        let bounded = PreparedChapterArchiveStore(directory: root, totalBudgetBytes: committed.count)
        do {
            try await bounded.write(bytes, bookID: "other", chapterIndex: 0, signature: signature)
            XCTFail("Budget exhaustion must reject the new entry")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: target()), committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target("other").path))
        do {
            try await bounded.write(Data(count: committed.count + 1), bookID: "book",
                                    chapterIndex: 0, signature: signature)
            XCTFail("Budget exhaustion must preserve the replaced entry")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: target()), committed)
    }

    func testSymlinkTargetIsRejectedWithoutChangingOldBytes() async throws {
        let original = root.appendingPathComponent("untouched.bin")
        try bytes.write(to: original)
        try FileManager.default.createSymbolicLink(at: target(), withDestinationURL: original)
        let store = PreparedChapterArchiveStore(directory: root)
        let value = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertNil(value)
        do {
            try await store.write(Data("replacement".utf8), bookID: "book", chapterIndex: 0, signature: signature)
            XCTFail("Symlink target must be rejected")
        } catch { }
        do {
            try await store.remove(bookID: "book", chapterIndex: 0)
            XCTFail("Symlink removal must be rejected")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target().path), original.path)
    }

    func testSymlinkRootAndDirectoryTargetAreRejected() async throws {
        let link = root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        for directory in [link, target()] {
            if directory == target() {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            let store = PreparedChapterArchiveStore(directory: directory == link ? link : root)
            do {
                try await store.write(bytes, bookID: "book", chapterIndex: 0, signature: signature)
                XCTFail("Non-regular target or symlink root must be rejected")
            } catch { }
            let value = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
            XCTAssertNil(value)
        }
    }

    @MainActor
    func testFileInspectionRunsOffMainActor() async throws {
        let probe = PreparedArchiveIOProbe()
        let store = PreparedChapterArchiveStore(directory: root, fileManager: probe)
        try await store.write(bytes, bookID: "book", chapterIndex: 0, signature: signature)
        let value = await store.read(bookID: "book", chapterIndex: 0, signature: signature)
        XCTAssertEqual(value, bytes)
        XCTAssertFalse(probe.mainThreadObservations.isEmpty)
        XCTAssertTrue(probe.mainThreadObservations.allSatisfy { !$0 })
    }

    func testInvalidKeysFailBeforeCreatingAStore() async throws {
        let directory = root.appendingPathComponent("must-not-create", isDirectory: true)
        let store = PreparedChapterArchiveStore(directory: directory)
        for (book, chapter, key) in [("", 0, signature), ("book", -1, signature),
                                     ("book", 0, "not-a-digest"), (String(repeating: "x", count: 1025), 0, signature)] {
            do {
                try await store.write(bytes, bookID: book, chapterIndex: chapter, signature: key)
                XCTFail("Invalid keys must be rejected before storage IO")
            } catch { }
            let value = await store.read(bookID: book, chapterIndex: chapter, signature: key)
            XCTAssertNil(value)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
