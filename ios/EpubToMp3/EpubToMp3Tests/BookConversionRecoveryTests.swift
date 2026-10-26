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
}
