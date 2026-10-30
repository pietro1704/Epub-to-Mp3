import Foundation
import XCTest
@testable import EpubToMp3

private actor BookDownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    let entered = XCTestExpectation(description: "Selected book maintenance entered")
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class BookDownloadMaintenanceTests: XCTestCase {
    func testSelectedBookWaitsWhileOtherBookDownloadsAndFailureReleasesQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = AudiobookDownloadStorage.rootOverrideForTesting
        AudiobookDownloadStorage.rootOverrideForTesting = root.appendingPathComponent("downloads")
        defer {
            AudiobookDownloadStorage.rootOverrideForTesting = previous
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("source.mp3")
        let bytes = Data(repeating: 23, count: 512)
        try bytes.write(to: source)
        let manager = AudiobookDownloads()
        let gate = BookDownloadGate()
        let maintenance = Task {
            try await manager.withBookStorageMaintenance(jobId: "selected") {
                await gate.wait()
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        for id in ["selected", "other"] {
            let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: JSONSerialization.data(withJSONObject: [
                "jobId": id, "state": "finished", "bookTitle": id,
                "chapterProgress": [["index": 0, "name": "Chapter", "status": "completed", "downloadUrl": source.absoluteString]]
            ]))
            await manager.enqueueAll(snapshot: snapshot, baseURL: nil)
        }
        let queued = await manager.watchProgress(jobId: "selected")
        var iterator = queued.makeAsyncIterator()
        let progress = await iterator.next()
        XCTAssertEqual(progress?.state, .queued)
        let otherFinished = await completed(manager, jobID: "other")
        XCTAssertTrue(otherFinished, "Another book's download must remain independent of the selected removal.")
        XCTAssertNil(AudiobookDownloadStorage.localAudioURL(jobId: "selected", chapterIndex: 0))
        await gate.release()
        do { try await maintenance.value; XCTFail("Filesystem failure must propagate") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteNoPermission.rawValue) }
        let selectedFinished = await completed(manager, jobID: "selected")
        XCTAssertTrue(selectedFinished, "Failed cleanup must release a newly requested download.")
        await manager.cancelAll()
        for id in ["selected", "other"] {
            let url = try XCTUnwrap(AudiobookDownloadStorage.localAudioURL(jobId: id, chapterIndex: 0))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    private func completed(_ manager: AudiobookDownloads, jobID: String) async -> Bool {
        for _ in 0..<100 {
            let stream = await manager.watchProgress(jobId: jobID)
            var iterator = stream.makeAsyncIterator()
            if await iterator.next()?.state == .completed { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
