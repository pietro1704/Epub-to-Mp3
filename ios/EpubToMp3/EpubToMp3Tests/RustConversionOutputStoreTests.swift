import Foundation
import XCTest
@testable import EpubToMp3

private actor OutputIdentityGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class RustConversionOutputStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("RustOutputs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func completed(_ store: RustConversionOutputStore, book: String, job: String) async throws -> URL {
        let lease = try await store.begin(bookID: book, jobID: job, cancel: {})
        let audio = lease.outputDirectory.appendingPathComponent("chapter.mp3")
        try Data([1, 2, 3, 4]).write(to: audio)
        await store.finish(lease)
        return audio
    }

    func testAllJobsForBookSurviveRestartAndRemovalPreservesOtherContent() async throws {
        let root = try fixture()
        let outputs = root.appendingPathComponent("outputs")
        let store = RustConversionOutputStore(root: outputs)
        let first = try await completed(store, book: "book-a", job: "a1")
        let second = try await completed(store, book: "book-a", job: "a2")
        let other = try await completed(store, book: "book-b", job: "b1")
        let source = root.appendingPathComponent("source.epub")
        let model = root.appendingPathComponent("model.onnx")
        try Data([7, 8]).write(to: source)
        try Data([9, 10]).write(to: model)
        let reopened = RustConversionOutputStore(root: outputs)
        try await reopened.removeAudio(bookID: "book-a", legacyJobID: "a2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(try Data(contentsOf: other), Data([1, 2, 3, 4]))
        XCTAssertEqual(try Data(contentsOf: source), Data([7, 8]))
        XCTAssertEqual(try Data(contentsOf: model), Data([9, 10]))
    }

    func testUsageScannerIncludesRustBytesAsProtectedAudio() throws {
        let root = try fixture()
        let legacy = root.appendingPathComponent("legacy-partial")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 41).write(to: legacy.appendingPathComponent("partial.mp3"))
        let baseline = StorageUsageScanner.current(rustOutputsRoot: root.appendingPathComponent("absent"))
        let actual = StorageUsageScanner.current(rustOutputsRoot: root)
        XCTAssertEqual(actual.offlineAudioBytes - baseline.offlineAudioBytes, 41)
        XCTAssertEqual(actual.totalBytes - baseline.totalBytes, 41)
        XCTAssertEqual(actual.ttsCacheBytes, baseline.ttsCacheBytes)
    }

    func testRemovalCancelsAndDrainsOnlyMatchingWriterBeforeDeleting() async throws {
        let root = try fixture()
        let store = RustConversionOutputStore(root: root)
        let cancelled = expectation(description: "matching writer cancelled")
        let otherCancelled = expectation(description: "other writer preserved")
        otherCancelled.isInverted = true
        let writer = try await store.begin(bookID: "book-a", jobID: "a", cancel: { cancelled.fulfill() })
        let other = try await store.begin(bookID: "book-b", jobID: "b", cancel: { otherCancelled.fulfill() })
        let removal = Task { try await store.removeAudio(bookID: "book-a") }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.outputDirectory.path))
        do {
            _ = try await store.begin(bookID: "book-a", jobID: "late", cancel: {})
            XCTFail("Registration during deletion must be rejected")
        } catch {}
        // A late native write still lands before deletion, never after it.
        try Data([8]).write(to: writer.outputDirectory.appendingPathComponent("late.mp3"))
        await store.finish(writer)
        try await removal.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.outputDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.outputDirectory.path))
        await store.finish(other)
        await fulfillment(of: [otherCancelled], timeout: 0.01)
    }

    func testPendingIdentityCannotRegisterAfterCompletedCleanup() async throws {
        let root = try fixture()
        let gate = OutputIdentityGate()
        let entered = expectation(description: "hashing started")
        let store = RustConversionOutputStore(root: root, bookIdentity: { _ in
            entered.fulfill()
            await gate.wait()
            return "book-a"
        })
        let pending = Task { try await store.begin(bookURL: root.appendingPathComponent("source"), jobID: "late", cancel: {}) }
        await fulfillment(of: [entered], timeout: 2)
        try await store.clearAllAudio()
        await gate.release()
        do { _ = try await pending.value; XCTFail("Old preparation must not resurrect output") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("late").path))
    }

    func testLegacyInputReceiptsRecoverAllJobsWithoutGuessingTitles() async throws {
        let root = try fixture()
        let outputs = root.appendingPathComponent("outputs")
        let jobs = outputs.appendingPathComponent(".jobs")
        try FileManager.default.createDirectory(at: jobs, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.epub")
        try Data([8, 9]).write(to: source)
        let bookID = try LibraryImportFiles.contentHash(of: source)
        for job in ["old-a1", "old-a2"] {
            let directory = outputs.appendingPathComponent(job)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("partial.mp3"))
            let record: [String: Any] = ["job_id": job, "metadata": ["input": source.path]]
            try JSONSerialization.data(withJSONObject: record).write(to: jobs.appendingPathComponent(job + ".json"))
        }
        let unrelated = outputs.appendingPathComponent("unknown")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try await RustConversionOutputStore(root: outputs).removeAudio(bookID: bookID)
        for job in ["old-a1", "old-a2"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputs.appendingPathComponent(job).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: jobs.appendingPathComponent(job + ".json").path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testClearAllCountsLegacyBytesAndReportsPreservedUnknownDirectories() async throws {
        let root = try fixture()
        let known = root.appendingPathComponent("known")
        let unknown = root.appendingPathComponent("unknown")
        for directory in [known, unknown] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("audio.mp3"))
        }
        let manifest = try JSONSerialization.data(withJSONObject: ["jobId": "known", "chapters": []] as [String: Any])
        try manifest.write(to: known.appendingPathComponent("manifest.json"))
        XCTAssertEqual(RustConversionOutputStore.storageBytes(at: root), Int64(6 + manifest.count))
        do { try await RustConversionOutputStore(root: root).clearAllAudio(); XCTFail("Unknown data must be reported") }
        catch { XCTAssertTrue(error is RustConversionOutputStore.StorageError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: known.path))
        XCTAssertEqual(try Data(contentsOf: unknown.appendingPathComponent("audio.mp3")), Data([1, 2, 3]))
    }

    func testCancelledMaintenanceDrainsWriterButPreservesItsOutput() async throws {
        let root = try fixture()
        let store = RustConversionOutputStore(root: root)
        let cancelled = expectation(description: "writer cancellation requested")
        let lease = try await store.begin(bookID: "book", jobID: "job", cancel: { cancelled.fulfill() })
        let operation = Task { try await store.clearAllAudio() }
        await fulfillment(of: [cancelled], timeout: 2)
        operation.cancel()
        await store.finish(lease)
        do { try await operation.value; XCTFail("Cancelled cleanup must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.outputDirectory.path))
        _ = try await completed(store, book: "another", job: "next")
    }

    func testRootAndJobSymlinksNeverGrantDeletionOfOutsideAudio() async throws {
        let root = try fixture()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let audio = outside.appendingPathComponent("keep.mp3")
        try Data([7]).write(to: audio)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        XCTAssertEqual(RustConversionOutputStore.storageBytes(at: alias), 0)
        do { try await RustConversionOutputStore(root: alias).clearAllAudio(); XCTFail("Symlink root must be rejected") }
        catch {}
        do { _ = try await RustConversionOutputStore(root: alias).begin(bookID: "book", jobID: "job", cancel: {}); XCTFail("Symlink root must reject writes") }
        catch {}
        let outputs = root.appendingPathComponent("outputs")
        try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: outputs.appendingPathComponent("foreign"), withDestinationURL: outside)
        try await RustConversionOutputStore(root: outputs).clearAllAudio()
        XCTAssertEqual(try Data(contentsOf: audio), Data([7]))
    }

    func testMetadataSymlinkAndWrongBookNeverAuthorizeBookRemoval() async throws {
        let root = try fixture()
        let outputs = root.appendingPathComponent("outputs")
        let store = RustConversionOutputStore(root: outputs)
        let other = try await completed(store, book: "other-book", job: "other-job")
        // A stale lastJobId must never override the durable book identity.
        try await store.removeAudio(bookID: "book", legacyJobID: "other-job")
        XCTAssertEqual(try Data(contentsOf: other), Data([1, 2, 3, 4]))
        let directory = outputs.appendingPathComponent("unrecognized")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fakeManifest = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["jobId": "unrecognized", "chapters": []] as [String: Any])
            .write(to: fakeManifest)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("manifest.json"),
                                                 withDestinationURL: fakeManifest)
        do { try await store.clearAllAudio(); XCTFail("Aliased manifest must not establish ownership") }
        catch { XCTAssertTrue(error is RustConversionOutputStore.StorageError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fakeManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testStaleLastJobIDCannotOverrideForeignLegacyInputIdentity() async throws {
        let root = try fixture()
        let outputs = root.appendingPathComponent("outputs")
        let directory = outputs.appendingPathComponent("foreign-job")
        let jobs = outputs.appendingPathComponent(".jobs")
        for folder in [directory, jobs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("book-b.epub")
        try Data([8, 9]).write(to: source)
        let sourceHash = try LibraryImportFiles.contentHash(of: source)
        let record = jobs.appendingPathComponent("foreign-job.json")
        let originalRecord = try JSONSerialization.data(withJSONObject: [
            "job_id": "foreign-job", "metadata": ["input": source.path]
        ] as [String: Any])
        try originalRecord.write(to: record)
        let manifest = try JSONSerialization.data(withJSONObject: [
            "jobId": "foreign-job", "chapters": []
        ] as [String: Any])
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        let audio = directory.appendingPathComponent("chapter.mp3")
        try Data([1, 2, 3]).write(to: audio)

        let store = RustConversionOutputStore(root: outputs)
        try await store.removeAudio(bookID: "book-a", legacyJobID: "foreign-job")
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: record), originalRecord)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), manifest)

        // The verified owner can still explicitly remove the same legacy job.
        try await store.removeAudio(bookID: sourceHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testCompletedJobIdentityCannotBeReusedOrRewriteExistingArtifacts() async throws {
        let root = try fixture()
        let store = RustConversionOutputStore(root: root)
        let audio = try await completed(store, book: "book", job: "job")
        let directory = audio.deletingLastPathComponent()
        let owner = directory.appendingPathComponent(".apple-output-owner.json")
        let originalOwner = try Data(contentsOf: owner)
        let log = directory.appendingPathComponent("conversion.log")
        let originalLog = Data("Original finished job\n".utf8)
        try originalLog.write(to: log)
        for attemptedStore in [store, RustConversionOutputStore(root: root)] {
            do {
                _ = try await attemptedStore.begin(bookID: "book", jobID: "job", cancel: {})
                XCTFail("A completed job directory is never implicitly resumed")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((error as NSError).code, CocoaError.fileWriteFileExists.rawValue)
            }
            XCTAssertEqual(try Data(contentsOf: owner), originalOwner)
            XCTAssertEqual(try Data(contentsOf: log), originalLog)
            XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3, 4]))
        }
    }

    func testIndependentStoresReserveOneJobDirectoryWithoutOverwritingWinner() async throws {
        let root = try fixture()
        let stores = [RustConversionOutputStore(root: root), RustConversionOutputStore(root: root)]
        let outcomes = await withTaskGroup(of: (String, RustConversionOutputStore.Lease?, Int?).self) { group in
            for (index, store) in stores.enumerated() {
                group.addTask {
                    let bookID = "book-\(index)"
                    do {
                        let lease = try await store.begin(bookID: bookID, jobID: "shared-job", cancel: {})
                        return (bookID, lease, nil)
                    } catch {
                        return (bookID, nil, (error as NSError).code)
                    }
                }
            }
            var results: [(String, RustConversionOutputStore.Lease?, Int?)] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
        let winners = outcomes.filter { $0.1 != nil }
        let losers = outcomes.filter { $0.1 == nil }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(losers.count, 1)
        XCTAssertEqual(losers.first?.2, CocoaError.fileWriteFileExists.rawValue)
        let winner = try XCTUnwrap(winners.first)
        let lease = try XCTUnwrap(winner.1)
        let ownerURL = lease.outputDirectory.appendingPathComponent(".apple-output-owner.json")
        let owner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ownerURL)) as? [String: Any])
        XCTAssertEqual(owner["bookID"] as? String, winner.0)
        XCTAssertEqual(owner["jobID"] as? String, "shared-job")
        for store in stores { await store.finish(lease) }
    }
}
