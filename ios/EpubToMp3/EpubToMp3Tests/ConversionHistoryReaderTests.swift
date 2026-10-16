import Foundation
import XCTest
#if os(iOS) && !APP_FOUNDATION_HOST_TESTS
import UIKit
#endif
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
    func testEmbeddedHistoryReadsTheBareManifestWrittenByRust() async throws {
        let root = try embeddedRoot()
        // converter-core's OutputManifest is persisted directly, not inside
        // the FFI response's separate {"manifest": ...} transport envelope.
        try writeEmbeddedManifest("""
        {"jobId":"rust-job","title":"Livro 😀","author":"Autor","archive":"book.zip",
         "chapters":[{"index":1,"sourceIndex":0,"title":"Opening","filename":"one.mp3","textChars":40}]}
        """, jobID: "rust-job", root: root)

        let snapshot = try await ConversionHistoryReader.loadEmbeddedManifests(from: root)

        XCTAssertFalse(snapshot.ioOnMainThread)
        XCTAssertEqual(snapshot.sessions.count, 1)
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.jobId, "rust-job")
        XCTAssertEqual(session.bookTitle, "Livro 😀")
        XCTAssertEqual(session.chaptersConverted, 1)
        XCTAssertEqual(session.outcome, "finished")
        XCTAssertEqual(session.mode, "embedded")
    }

    @MainActor
    func testEmbeddedHistorySkipsCorruptUnfinishedAndMismatchedJobs() async throws {
        let root = try embeddedRoot()
        for (jobID, contents) in [
            ("good", "{\"jobId\":\"good\",\"title\":\"Retained\",\"chapters\":[{}]}"),
            ("corrupt", "{\"jobId\":"),
            ("empty", "{\"jobId\":\"empty\",\"title\":\"Empty\",\"chapters\":[]}"),
            ("missing-fields", "{\"jobId\":\"missing-fields\",\"title\":\"Incomplete\"}"),
            ("mismatched", "{\"jobId\":\"another-job\",\"title\":\"Wrong identity\",\"chapters\":[{}]}"),
            ("legacy-mismatched", "{\"manifest\":{\"jobId\":\"another-job\",\"title\":\"Wrong legacy identity\",\"chapters\":[{}]}}"),
        ] {
            try writeEmbeddedManifest(contents, jobID: jobID, root: root)
        }
        // In-progress/cancelled conversions have no committed output manifest.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("in-progress"), withIntermediateDirectories: false)
        try writeEmbeddedManifest(String(repeating: " ", count: 1_048_577), jobID: "oversized", root: root)

        let snapshot = try await ConversionHistoryReader.loadEmbeddedManifests(from: root)

        XCTAssertEqual(snapshot.sessions.map(\.jobId), ["good"])
        XCTAssertEqual(snapshot.sessions.map(\.bookTitle), ["Retained"])
    }

    private func embeddedRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeEmbeddedManifest(_ contents: String, jobID: String, root: URL) throws {
        let directory = root.appendingPathComponent(jobID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(contents.utf8).write(to: directory.appendingPathComponent("manifest.json"))
    }

    #if os(iOS) && !APP_FOUNDATION_HOST_TESTS
    @MainActor
    func testForegroundJobsScreenShowsThePersistedRustManifest() async throws {
        let jobID = "history-screen-\(UUID().uuidString)"
        let title = "Persisted Rust book \(jobID)"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("EpubToMp3/RustConversions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeEmbeddedManifest("""
        {"jobId":"\(jobID)","title":"\(title)","author":"Author","archive":"book.zip",
         "chapters":[{"index":1,"sourceIndex":0,"title":"Opening","filename":"one.mp3","textChars":40}]}
        """, jobID: jobID, root: root)
        // Remove only this test's uniquely named job, preserving all user history.
        defer { try? FileManager.default.removeItem(at: root.appendingPathComponent(jobID)) }
        let suite = "ConversionHistoryReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = JobsListScreenController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults), player: AudioPlayer(), playbackClock: PlaybackClock())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        screen.loadViewIfNeeded()
        let child = try XCTUnwrap(screen.children.first as? JobsListController)
        let table = try XCTUnwrap(child.view as? UITableView)
        var matchedCell: UITableViewCell?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && matchedCell == nil {
            let rows = table.dataSource?.tableView(table, numberOfRowsInSection: 0) ?? 0
            for row in 0..<rows {
                let cell = table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: row, section: 0))
                if cell?.accessibilityLabel == title { matchedCell = cell; break }
            }
            if matchedCell == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let cell = try XCTUnwrap(matchedCell, "The shipped Jobs screen must display the actual Rust disk format.")
        XCTAssertFalse(table.isHidden)
        XCTAssertEqual(cell.accessoryType, .disclosureIndicator)
        XCTAssertFalse((cell.accessibilityValue ?? "").isEmpty)
    }
    #endif

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
