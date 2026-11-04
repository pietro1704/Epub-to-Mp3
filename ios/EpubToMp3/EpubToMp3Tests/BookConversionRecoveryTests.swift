import XCTest
import CryptoKit
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class BookConversionRecoveryTests: XCTestCase {
    func testRepeatedFailedResumeRetainsTheVerifiedAncestor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        try Data("immutable source".utf8).write(to: source)
        let store = BookConversionRecoveryStore(root: root)
        let originalJob = UUID().uuidString
        let bookID = try await store.begin(bookURL: source, jobID: originalJob, options: ConversionOptions(engine: "piper"))
        let directory = root.appendingPathComponent(originalJob)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["bookID": bookID, "jobID": originalJob]).write(
            to: directory.appendingPathComponent(".apple-output-owner.json"))
        let audio = Data("receipt-integrity fixture, not an inference claim".utf8)
        try audio.write(to: directory.appendingPathComponent("0001-chapter.mp3"))
        try JSONSerialization.data(withJSONObject: ["version": 2, "size": audio.count,
            "audio_sha256": SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()]).write(
                to: directory.appendingPathComponent("0001-chapter.mp3.complete.json"))
        try await store.progress(bookID: bookID, jobID: originalJob, total: 20, completed: 0)
        try await store.finish(bookID: bookID, jobID: originalJob, succeeded: false)
        for _ in 0..<3 {
            let pending = try await store.pending(bookID: bookID)
            let record = try XCTUnwrap(pending)
            XCTAssertEqual(record.jobID, originalJob)
            XCTAssertEqual(record.completed, [0])
            let next = UUID().uuidString
            try FileManager.default.createDirectory(at: root.appendingPathComponent(next), withIntermediateDirectories: true)
            _ = try await store.begin(bookURL: source, jobID: next, options: record.resumeOptions)
            try await store.finish(bookID: bookID, jobID: next, succeeded: false)
        }
        let after = try await store.pending(bookID: bookID)
        XCTAssertEqual(after?.jobID, originalJob)
        try Data("corrupted".utf8).write(to: directory.appendingPathComponent("0001-chapter.mp3"))
        let corrupted = try await store.pending(bookID: bookID)
        XCTAssertEqual(corrupted?.completed.count, 0)
    }

    func testFailedExportKeepsCapturedOptionsAndRejectsLateEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        try Data("immutable book fixture".utf8).write(to: source)
        let jobID = UUID().uuidString
        try FileManager.default.createDirectory(at: root.appendingPathComponent(jobID), withIntermediateDirectories: true)
        let store = BookConversionRecoveryStore(root: root.resolvingSymlinksInPath())
        var options = ConversionOptions(engine: "piper", clearCache: true)
        options.forceReprocess = true
        let bookID = try await store.begin(bookURL: source, jobID: jobID, options: options)
        let active = try await store.pending(bookID: bookID)
        XCTAssertNil(active)
        try await store.progress(bookID: bookID, jobID: jobID, total: 20, completed: 0)
        try await store.finish(bookID: bookID, jobID: jobID, succeeded: false)
        try await store.progress(bookID: bookID, jobID: jobID, total: 999, completed: 1)
        let pending = try await store.pending(bookID: bookID)
        let record = try XCTUnwrap(pending)
        XCTAssertEqual(record.chaptersTotal, 20)
        XCTAssertEqual(record.completed.count, 0, "An event without verified audio is not reusable work")
        XCTAssertEqual(record.resumeOptions.recoveryJobID, jobID)
        XCTAssertEqual(record.resumeOptions.engine, "piper")
        XCTAssertEqual(record.resumeOptions.pronunciation?.rules, [], "Resume captures the absence of pronunciation rules too")
        XCTAssertFalse(record.resumeOptions.clearCache)
        XCTAssertFalse(record.resumeOptions.forceReprocess)
        try await store.finish(bookID: bookID, jobID: jobID, succeeded: true)
        let finished = try await store.pending(bookID: bookID)
        XCTAssertNil(finished)
    }

    func testRecoveryRejectsAnotherBookAndDoesNotInventCompletionAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        try Data("source".utf8).write(to: source)
        let jobID = UUID().uuidString
        try FileManager.default.createDirectory(at: root.appendingPathComponent(jobID), withIntermediateDirectories: true)
        let first = BookConversionRecoveryStore(root: root)
        let bookID = try await first.begin(bookURL: source, jobID: jobID, options: nil)
        let recovered = BookConversionRecoveryStore(root: root)
        let record = try await recovered.pending(bookID: bookID)
        XCTAssertEqual(record?.completed, [])
        let unknown = try await recovered.pending(bookID: String(repeating: "0", count: 32))
        XCTAssertNil(unknown)
    }

    func testRecoveryPreservesCompleteOrdinalsAcrossFourDigitBoundary() async throws {
        let fixture = try await RecoveryOrdinalFixture.create()
        defer { fixture.cleanUp() }
        for filename in ["0001-start.mp3", "1000-chapter.mp3", "9999-boundary.mp3",
                         "10000-chapter.mp3", "10001-title-with-more-hyphens.mp3"] {
            try fixture.writeAudio(filename)
        }
        try await fixture.interrupt()

        let pending = try await fixture.store.pending(bookID: fixture.bookID)
        let record = try XCTUnwrap(pending)

        XCTAssertEqual(record.completed, [0, 999, 9998, 9999, 10000])
        XCTAssertEqual(record.chaptersTotal, 10001)
        XCTAssertTrue(record.interrupted)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    }

    func testLargeOrdinalsStillRequireVerifiedCompletionReceipts() async throws {
        let fixture = try await RecoveryOrdinalFixture.create()
        defer { fixture.cleanUp() }
        let valid = try fixture.writeAudio("10000-verified.mp3")
        let missing = try fixture.writeAudio("10001-missing.mp3", receipt: .missing)
        let wrongSize = try fixture.writeAudio("10002-size.mp3", receipt: .wrongSize)
        let wrongHash = try fixture.writeAudio("10003-hash.mp3", receipt: .wrongHash)
        let oldVersion = try fixture.writeAudio("10004-version.mp3", receipt: .wrongVersion)
        let malformed = try fixture.writeAudio("10005-malformed.mp3", receipt: .malformed)
        let changed = try fixture.writeAudio("10006-changed.mp3")
        try Data("Changed after Rust completion receipt was written.".utf8).write(to: changed)
        let files = [valid, missing, wrongSize, wrongHash, oldVersion, malformed, changed]
        let bytes = try files.map { try Data(contentsOf: $0) }
        try await fixture.interrupt(total: 10006)

        let pending = try await fixture.store.pending(bookID: fixture.bookID)

        XCTAssertEqual(pending?.completed, [9999])
        for (url, original) in zip(files, bytes) {
            XCTAssertEqual(try Data(contentsOf: url), original, "Recovery must preserve ignored audio too")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    }

    func testMatchingReceiptsCannotAuthorizeMalformedOrdinalFilenames() async throws {
        let fixture = try await RecoveryOrdinalFixture.create()
        defer { fixture.cleanUp() }
        let invalidNames = [
            "0000-zero.mp3", "10000.mp3", "10000chapter.mp3", "10000x-chapter.mp3",
            "+10000-chapter.mp3", "-10000-chapter.mp3", " 10000-chapter.mp3",
            "10000.5-chapter.mp3", "١٠٠٠٠-chapter.mp3", "123-short.mp3",
            "999999999999999999999999-overflow.mp3"
        ]
        for filename in invalidNames { try fixture.writeAudio(filename) }
        try fixture.writeAudio("0001-title-with-more-hyphens.mp3")
        try await fixture.interrupt()

        let pending = try await fixture.store.pending(bookID: fixture.bookID)

        XCTAssertEqual(pending?.completed, [0])
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    }

    func testLargeOrdinalsRequireMatchingBookAndJobOwnership() async throws {
        let fixture = try await RecoveryOrdinalFixture.create()
        defer { fixture.cleanUp() }
        let audio = try fixture.writeAudio("10000-chapter.mp3")
        let original = try Data(contentsOf: audio)
        try await fixture.interrupt()
        for owner in [(String(repeating: "0", count: 32), fixture.jobID), (fixture.bookID, UUID().uuidString)] {
            try fixture.writeOwner(bookID: owner.0, jobID: owner.1)

            let foreign = try await fixture.store.pending(bookID: fixture.bookID)

            XCTAssertEqual(foreign?.completed, [])
            XCTAssertEqual(try Data(contentsOf: audio), original)
        }
        try fixture.writeOwner()

        let restored = try await fixture.store.pending(bookID: fixture.bookID)

        XCTAssertEqual(restored?.completed, [9999])
    }

    func testRelaunchChoosesAncestorWithMoreDistinctLargeOrdinals() async throws {
        let fixture = try await RecoveryOrdinalFixture.create()
        defer { fixture.cleanUp() }
        for filename in ["1000-chapter.mp3", "10000-chapter.mp3", "10001-chapter.mp3"] {
            try fixture.writeAudio(filename)
        }
        try await fixture.interrupt()
        let pending = try await fixture.store.pending(bookID: fixture.bookID)
        let original = try XCTUnwrap(pending)
        let retryJob = UUID().uuidString
        _ = try await fixture.store.begin(bookURL: fixture.source, jobID: retryJob, options: original.resumeOptions)
        try fixture.writeOwner(directoryJobID: retryJob, jobID: retryJob)
        try fixture.writeAudio("0001-retry.mp3", jobID: retryJob)
        try fixture.writeAudio("0002-retry.mp3", jobID: retryJob)
        try await fixture.store.finish(bookID: fixture.bookID, jobID: retryJob, succeeded: false)
        let relaunched = BookConversionRecoveryStore(root: fixture.root)

        let recovered = try await relaunched.pending(bookID: fixture.bookID)
        let record = try XCTUnwrap(recovered)

        XCTAssertEqual(record.jobID, fixture.jobID, "Three distinct ancestor chapters beat two retry chapters")
        XCTAssertEqual(record.completed, [999, 9999, 10000])
        XCTAssertEqual(record.chaptersTotal, 10001)
        XCTAssertEqual(record.resumeOptions.recoveryJobID, fixture.jobID)
        XCTAssertFalse(record.resumeOptions.clearCache)
        XCTAssertFalse(record.resumeOptions.forceReprocess)
        XCTAssertEqual(try Data(contentsOf: fixture.source), fixture.sourceBytes)
    }
}

private struct RecoveryOrdinalFixture {
    enum Receipt { case valid, missing, wrongSize, wrongHash, wrongVersion, malformed }

    let root: URL
    let source: URL
    let sourceBytes: Data
    let jobID: String
    let bookID: String
    let store: BookConversionRecoveryStore

    static func create() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("book.epub")
            let bytes = Data("Immutable source for receipt-integrity recovery, not book parsing.".utf8)
            try bytes.write(to: source)
            let store = BookConversionRecoveryStore(root: root)
            let jobID = UUID().uuidString
            let bookID = try await store.begin(bookURL: source, jobID: jobID, options: ConversionOptions(engine: "piper"))
            let fixture = Self(root: root, source: source, sourceBytes: bytes, jobID: jobID, bookID: bookID, store: store)
            try fixture.writeOwner()
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func writeOwner(directoryJobID: String? = nil, bookID: String? = nil, jobID: String? = nil) throws {
        let directory = root.appendingPathComponent(directoryJobID ?? self.jobID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["bookID": bookID ?? self.bookID, "jobID": jobID ?? self.jobID])
            .write(to: directory.appendingPathComponent(".apple-output-owner.json"))
    }

    @discardableResult
    func writeAudio(_ filename: String, jobID: String? = nil, receipt: Receipt = .valid) throws -> URL {
        let directory = root.appendingPathComponent(jobID ?? self.jobID)
        let audio = directory.appendingPathComponent(filename)
        let bytes = Data("Receipt integrity bytes for \(filename), not playable speech.".utf8)
        try bytes.write(to: audio)
        let receiptURL = directory.appendingPathComponent(filename + ".complete.json")
        var fields: [String: Any] = ["version": 2, "size": bytes.count,
            "audio_sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        switch receipt {
        case .valid: break
        case .missing: return audio
        case .wrongSize: fields["size"] = bytes.count + 1
        case .wrongHash: fields["audio_sha256"] = String(repeating: "0", count: 64)
        case .wrongVersion: fields["version"] = 1
        case .malformed:
            try Data("{".utf8).write(to: receiptURL)
            return audio
        }
        try JSONSerialization.data(withJSONObject: fields).write(to: receiptURL)
        return audio
    }

    func interrupt(total: Int = 10001) async throws {
        try await store.progress(bookID: bookID, jobID: jobID, total: total)
        try await store.finish(bookID: bookID, jobID: jobID, succeeded: false)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
