import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ConversionHistoryReaderTests: XCTestCase {
    private func log(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversions.jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testMalformedAndIncompleteRecordsDoNotDiscardValidUTF8History() throws {
        let url = try log("{\"timestamp\":\"1\",\"book_title\":\"Primeiro\"}\ninvalid\n{\"timestamp\":\"2\",\"book_title\":\"Último 😀 漢字\"}\r\n{\"timestamp\":")
        let snapshot = try ConversionHistoryReader.readLatest(from: url)
        XCTAssertEqual(snapshot.sessions.map(\.timestamp), ["2", "1"])
        XCTAssertEqual(snapshot.sessions.first?.bookTitle, "Último 😀 漢字")
    }

    func testByteBudgetSkipsOversizedLeadingRecordAndPreservesRecentRecords() throws {
        let giant = String(repeating: "😀", count: 20_000)
        let url = try log("{\"timestamp\":\"old\",\"book_title\":\"\(giant)\"}\n{\"timestamp\":\"new\",\"book_title\":\"Newest\"}")
        let snapshot = try ConversionHistoryReader.readLatest(from: url, byteBudget: 4096)
        XCTAssertEqual(snapshot.bytesRead, 4096)
        XCTAssertTrue(snapshot.budgetExhausted)
        XCTAssertEqual(snapshot.sessions.map(\.timestamp), ["new"])
    }

    func testZeroLimitDoesNotOpenTheSource() throws {
        let snapshot = try ConversionHistoryReader.readLatest(from: URL(fileURLWithPath: "/unused-history-source"), limit: 0)
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertEqual(snapshot.bytesRead, 0)
    }

    func testBlankTrailingLinesDoNotHideEarlierHistory() throws {
        let url = try log("{\"timestamp\":\"1\",\"book_title\":\"Retained\"}\n" + String(repeating: "\r\n", count: 20_000))
        let snapshot = try ConversionHistoryReader.readLatest(from: url)
        XCTAssertEqual(snapshot.sessions.map(\.timestamp), ["1"])
        XCTAssertFalse(snapshot.budgetExhausted)
    }

    @MainActor
    func testAsyncHistoryLoadPerformsIOOutsideTheMainThread() async throws {
        XCTAssertTrue(Thread.isMainThread)
        let url = try log("{\"timestamp\":\"1\",\"book_title\":\"Book\"}\n")
        let snapshot = try await ConversionHistoryReader.loadLatest(from: url)
        XCTAssertFalse(snapshot.ioOnMainThread)
        XCTAssertEqual(snapshot.sessions.first?.bookTitle, "Book")
    }

    @MainActor
    func testAlreadyCancelledLoadFailsWithoutOpeningTheSource() async throws {
        let task = Task { @MainActor in
            try await ConversionHistoryReader.loadLatest(from: URL(fileURLWithPath: "/unused-history-source"))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled load unexpectedly succeeded")
        } catch is CancellationError {
            // A missing-file error would prove cancelled work still performed IO.
        }
    }

    func testRecentHistoryReadsABoundedTailInsteadOfTheWholeArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("conversions.jsonl")
        let padding = String(repeating: "old history payload ", count: 40)
        var fixture = Data()
        for index in 0..<10_000 {
            fixture.append(Data("{\"timestamp\":\"\(index)\",\"book_title\":\"\(padding)\(index)\"}\n".utf8))
        }
        try fixture.write(to: url)
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = try ConversionHistoryReader.readLatest(from: url, limit: 100)
        let readMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        XCTAssertEqual(snapshot.sessions.count, 100)
        XCTAssertEqual(snapshot.sessions.first?.timestamp, "9999")
        XCTAssertEqual(snapshot.sessions.last?.timestamp, "9900")
        XCTAssertLessThanOrEqual(snapshot.bytesRead, 128 * 1024)
        print("[History IO] archiveBytes=\(fixture.count) bytesRead=\(snapshot.bytesRead) records=\(snapshot.sessions.count) readMs=\(readMilliseconds)")
    }

    @MainActor
    func testEmbeddedManifestHistoryLoadsOffMainAndPreservesNewestFirstOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, title, date) in [
            ("old", "Older book", Date(timeIntervalSince1970: 1)),
            ("new", "Newest book", Date(timeIntervalSince1970: 2)),
        ] {
            let directory = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let manifest = """
            {"manifest":{"jobId":"\(id)","title":"\(title)","chapters":[{}]}}
            """
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
        }

        let snapshot = try await ConversionHistoryReader.loadEmbeddedManifests(from: root)

        XCTAssertFalse(snapshot.ioOnMainThread)
        let sessions = snapshot.sessions
        XCTAssertEqual(sessions.map(\.jobId), ["new", "old"])
        XCTAssertEqual(sessions.map(\.bookTitle), ["Newest book", "Older book"])
        XCTAssertTrue(sessions.allSatisfy { $0.engine == "Rust" && $0.mode == "embedded" })
    }

    @MainActor
    func testCancelledEmbeddedManifestHistoryDoesNotStartIO() async {
        let task = Task { @MainActor in
            try await ConversionHistoryReader.loadEmbeddedManifests(from: URL(fileURLWithPath: "/unused-history-root"))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled load unexpectedly succeeded")
        } catch is CancellationError {
            // A missing-root error would prove cancelled work still performed IO.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
