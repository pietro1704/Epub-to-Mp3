import XCTest
@testable import EpubToMp3

final class ConversionCallbackBoundaryTests: XCTestCase {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.lock(); defer { lock.unlock() }; storage.append(line) }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func progress(job: String = "active", version: Int? = nil, chapter: Int = 0) throws -> Data {
        var json: [String: Any] = ["jobId": job, "state": "running", "chapterIndex": chapter,
            "chaptersTotal": 1, "chaptersCompleted": 0, "percent": 0, "message": "PRIVATE BOOK TEXT"]
        json["version"] = version
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testMalformedCallbackIsDiagnosedWithoutPayloadAndValidProgressStillArrives() throws {
        let capture = Capture()
        let boundary = ConversionCallbackBoundary(jobID: "active", diagnostic: { capture.append($0) })
        XCTAssertNil(boundary.progress(Data("PRIVATE BOOK TEXT".utf8)))
        XCTAssertEqual(boundary.progress(try progress())?.jobId, "active")
        let line = try XCTUnwrap(capture.lines.first)
        XCTAssertFalse(line.contains("PRIVATE BOOK TEXT"))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["jobID"] as? String, "active")
        XCTAssertEqual(record["event"] as? String, "progress")
        XCTAssertEqual(record["reason"] as? String, "invalid_payload")
        XCTAssertEqual(record["action"] as? String, "drop_notification")
    }

    func testUnsupportedVersionForeignIdentityAndLateCallbacksAreRejected() throws {
        let capture = Capture()
        let boundary = ConversionCallbackBoundary(jobID: "active", diagnostic: { capture.append($0) })
        XCTAssertNil(boundary.progress(try progress(version: 99)))
        XCTAssertNil(boundary.progress(try progress(job: "foreign")))
        XCTAssertNotNil(boundary.progress(try progress(version: 1)))
        boundary.finish()
        XCTAssertNil(boundary.progress(try progress()))
        XCTAssertEqual(capture.lines.count, 3)
        XCTAssertTrue(capture.lines.contains { $0.contains("unsupported_version") && $0.contains("99") })
        XCTAssertTrue(capture.lines.contains { $0.contains("foreign_job") })
        XCTAssertTrue(capture.lines.contains { $0.contains("late_callback") })
    }

    func testCancellationRejectsDeliveryAndRepeatedErrorsAreBounded() throws {
        let capture = Capture()
        let boundary = ConversionCallbackBoundary(jobID: "active", cancelled: { true }, diagnostic: { capture.append($0) })
        for _ in 0..<100 { XCTAssertNil(boundary.progress(try progress())) }
        XCTAssertEqual(capture.lines.count, 1)
        XCTAssertTrue(capture.lines.first?.contains("cancelled") == true)
    }

    func testChapterMappingFailureIsDiagnosedAndValidChapterPreservesLiteralPath() throws {
        let capture = Capture()
        let map = try JSONDecoder().decode(ReaderConversionChapterMap.self,
            from: Data(#"{"coreToReader":{"0":3},"coreTextChars":{"0":50}}"#.utf8))
        let boundary = ConversionCallbackBoundary(jobID: "active", chapterMap: map, diagnostic: { capture.append($0) })
        XCTAssertNil(boundary.progress(try progress(chapter: 99)))
        XCTAssertEqual(boundary.progress(try progress())?.chapterIndex, 3)
        let payload = Data(#"{"jobId":"active","bookTitle":"PRIVATE BOOK TEXT","bookAuthor":"Author","chapterIndex":0,"chaptersTotal":1,"chaptersCompleted":1,"chapterTitle":"PRIVATE BOOK TEXT","filename":"one #1.mp3","audioPath":"/fixture/one #1.mp3","textChars":50}"#.utf8)
        let chapter = try XCTUnwrap(boundary.chapter(payload))
        XCTAssertEqual(chapter.chapterIndex, 3)
        XCTAssertEqual(chapter.audioPath.path, "/fixture/one #1.mp3")
        XCTAssertNil(boundary.chapter(try progress()))
        XCTAssertEqual(capture.lines.count, 2)
        XCTAssertTrue(capture.lines.contains { $0.contains("chapter_mapping") })
        XCTAssertTrue(capture.lines.allSatisfy { !$0.contains("PRIVATE BOOK TEXT") })
    }
}
