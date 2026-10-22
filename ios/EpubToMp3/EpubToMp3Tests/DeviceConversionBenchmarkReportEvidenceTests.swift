import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import EpubToMp3

extension DeviceConversionBenchmarkTests {
    func testReportIncludesProviderMetadataAndExplicitNulls() throws {
        var entry = DeviceBenchmarkReport.Case(bookPath: "book.epub", chapterStart: 0, chapterEnd: 1)
        let empty = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for key in ["engine", "voice", "language"] {
            XCTAssertTrue(empty[key] is NSNull, key)
        }
        entry.engine = "edge"
        entry.voice = "en-US-AriaNeural"
        entry.language = "en-US"
        let populated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(populated["engine"] as? String, entry.engine)
        XCTAssertEqual(populated["voice"] as? String, entry.voice)
        XCTAssertEqual(populated["language"] as? String, entry.language)
    }

    func testFootprintCaptureReportsNativeStatusAndPositiveBytes() throws {
        let sample = BenchmarkFootprintSample.capture()
        XCTAssertEqual(sample.memoryStatus, KERN_SUCCESS)
        guard sample.memoryStatus == KERN_SUCCESS else { return }
        let bytes = try XCTUnwrap(sample.physicalFootprintBytes)
        XCTAssertGreaterThan(bytes, 0)
    }

    @MainActor
    func testDeliveryMetricKeepsFirstChapterAndMonotonicElapsedTime() {
        let recorder = BenchmarkDeliveryRecorder(startedAt: 1_000_000_000,
            before: .init(physicalFootprintBytes: 4096, memoryStatus: KERN_SUCCESS))
        XCTAssertFalse(recorder.record(chapterIndex: 4, deliveredAt: 999_999_999))
        XCTAssertNil(recorder.measurements.firstPlayableChapterDeliverySeconds)
        XCTAssertTrue(recorder.record(chapterIndex: 5, deliveredAt: 1_250_000_000))
        XCTAssertFalse(recorder.record(chapterIndex: 4, deliveredAt: 2_000_000_000))
        XCTAssertEqual(recorder.measurements.firstPlayableChapterIndex, 5)
        XCTAssertEqual(recorder.measurements.firstPlayableChapterDeliverySeconds, 0.25)
    }

    func testReportAddsFootprintAndDeliveryWithoutChangingExistingSchema() throws {
        var entry = DeviceBenchmarkReport.Case(bookPath: "fixture.epub", chapterStart: 4, chapterEnd: 5)
        entry.conversionMeasurements.beforeSynthesis = .init(physicalFootprintBytes: 8192, memoryStatus: KERN_SUCCESS)
        entry.conversionMeasurements.afterSynthesis = .init(physicalFootprintBytes: 4096, memoryStatus: KERN_SUCCESS)
        entry.conversionMeasurements.firstPlayableChapterDeliverySeconds = 0.25
        entry.conversionMeasurements.firstPlayableChapterIndex = 4
        let report = DeviceBenchmarkReport(runID: UUID().uuidString, cases: [entry])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases[0]["chapterStart"] as? Int, 4)
        XCTAssertEqual(cases[0]["chapterEnd"] as? Int, 5)
        XCTAssertEqual(cases[0]["synthesisSeconds"] as? Double, 0)
        XCTAssertTrue(cases[0]["engine"] is NSNull)
        let metrics = try XCTUnwrap(cases[0]["conversionMeasurements"] as? [String: Any])
        let before = try XCTUnwrap(metrics["beforeSynthesis"] as? [String: Any])
        let after = try XCTUnwrap(metrics["afterSynthesis"] as? [String: Any])
        XCTAssertEqual(before["physicalFootprintBytes"] as? UInt64, 8192)
        XCTAssertEqual(after["physicalFootprintBytes"] as? UInt64, 4096)
        XCTAssertEqual(metrics["firstPlayableChapterDeliverySeconds"] as? Double, 0.25)
        XCTAssertEqual(metrics["firstPlayableChapterIndex"] as? Int, 4)
        XCTAssertTrue(try XCTUnwrap(metrics["semantics"] as? String).contains("not acoustic"))
    }

    func testReportDoesNotInventMissingDeliveryOrUnavailableFootprint() throws {
        var metrics = BenchmarkConversionMeasurements()
        metrics.beforeSynthesis = .init(physicalFootprintBytes: nil, memoryStatus: KERN_FAILURE)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics)) as? [String: Any])
        XCTAssertNil(object["firstPlayableChapterDeliverySeconds"])
        XCTAssertNil(object["firstPlayableChapterIndex"])
        XCTAssertNil(object["afterSynthesis"])
        let before = try XCTUnwrap(object["beforeSynthesis"] as? [String: Any])
        XCTAssertNil(before["physicalFootprintBytes"])
        XCTAssertEqual(before["memoryStatus"] as? Int32, KERN_FAILURE)
    }

    func testReportPreservesConversionErrorWhenCleanupAlsoFails() throws {
        var report = DeviceBenchmarkReport(runID: UUID().uuidString, cases: [
            .init(bookPath: "book.epub", chapterStart: 0, chapterEnd: 1)
        ])
        let original = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSLocalizedDescriptionKey: "Original conversion failure",
            NSFilePathErrorKey: "/staged/run/Contents/PkgInfo",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2)
        ])
        report.recordFailure(original, context: "conversion", caseIndex: 0)
        report.recordFailure(NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
            NSLocalizedDescriptionKey: "Secondary cleanup failure"
        ]), context: "output cleanup")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.encoded()) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertEqual(object["error"] as? String, original.localizedDescription)
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases[0]["error"] as? String, original.localizedDescription)
        let errors = try XCTUnwrap(object["errors"] as? [String])
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors[0].contains("Contents/PkgInfo"))
        XCTAssertTrue(errors[0].contains("code=260"))
        XCTAssertTrue(errors[1].contains("code=513"))
    }

    func testTemporaryStorageSpecAndReportRoundTrip() throws {
        let owned = try BenchmarkInputCopies()
        defer { try? FileManager.default.removeItem(at: owned.directory) }
        let spec = specification()
        let json = String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
        let decoded = try DeviceBenchmarkSpec.decode(json, temporaryRoot: owned.directory)
        XCTAssertEqual(decoded.inputBase, "temporary")
        XCTAssertEqual(decoded.stagedDirectory(temporaryRoot: owned.directory),
                       owned.directory.appendingPathComponent("EpubToMp3/DeviceTestInputs/\(spec.runID)", isDirectory: true))
        let invalid = DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "applicationSupport",
                                          runID: spec.runID, wholeBook: false, cases: spec.cases)
        XCTAssertThrowsError(try invalid.validate(temporaryRoot: owned.directory))
        let report = DeviceBenchmarkReport(runID: spec.runID, cases: [])
        let destination = owned.directory.appendingPathComponent("DeviceBenchmarkReports/\(spec.runID).json")
        let bytes = try report.save(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testPressureMetricsCountEventsWithoutSummingRetryCounters() {
        let lines = ["tts chunk=1/1 retries=1 result=pressure:Throttle",
                     "tts chunk=1/1 retries=2 result=pressure:Timeout",
                     "tts chunk=1/1 retries=2 result=success"]
        XCTAssertEqual(lines.filter { DeviceBenchmarkReport.Case.result($0)?.hasPrefix("pressure:") == true }.count, 2)
        XCTAssertEqual(lines.filter { DeviceBenchmarkReport.Case.result($0) == "pressure:Throttle" }.count, 1)
    }
}
