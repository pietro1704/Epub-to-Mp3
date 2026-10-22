import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import EpubToMp3

extension DeviceConversionBenchmarkTests {
    func testScopeAcceptsOneAndTwoChapters() throws {
        try specification(start: 0, end: 0).validate(temporaryRoot: validationRoot)
        try specification().validate(temporaryRoot: validationRoot)
    }

    func testScopeRejectsOversizedReversedAndMixedSentinels() {
        for (start, end) in [(0, 2), (5, 4), (-1, 0), (0, -1), (-2, -2), (Int.max, Int.max)] {
            for wholeBook in [false, true] {
                XCTAssertThrowsError(try specification(start: start, end: end, wholeBook: wholeBook)
                    .validate(temporaryRoot: validationRoot))
            }
        }
    }

    func testScopeRequiresExplicitWholeBookOptIn() throws {
        XCTAssertThrowsError(try specification(start: -1, end: -1).validate(temporaryRoot: validationRoot))
        try specification(start: -1, end: -1, wholeBook: true).validate(temporaryRoot: validationRoot)
    }

    func testScopeRejectsMalformedMissingAndUnsupportedSchema() throws {
        let valid = try JSONEncoder().encode(specification())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for key in ["schemaVersion", "inputBase", "runID", "wholeBook", "cases"] {
            var missing = object
            missing.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missing)
            XCTAssertThrowsError(try DeviceBenchmarkSpec.decode(String(decoding: data, as: UTF8.self), temporaryRoot: validationRoot))
        }
        object["schemaVersion"] = 1
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try DeviceBenchmarkSpec.decode(String(decoding: data, as: UTF8.self), temporaryRoot: validationRoot))
        XCTAssertThrowsError(try DeviceBenchmarkSpec.decode("{", temporaryRoot: validationRoot))
    }

    func testScopeRejectsTraversalAndOtherRunPaths() {
        let spec = specification()
        for path in ["/tmp/book.epub", "EpubToMp3/DeviceTestInputs/\(spec.runID)/../book.epub",
                     "EpubToMp3/DeviceTestInputs/\(spec.runID)/%2e%2e.epub",
                     "EpubToMp3/DeviceTestInputs/\(UUID().uuidString)/book.epub",
                     "EpubToMp3/DeviceTestInputs/\(spec.runID)/nested/book.epub",
                     "EpubToMp3/DeviceTestInputs/\(spec.runID)/book\\other.epub"] {
            let invalid = DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: [
                .init(bookPath: path, chapterStart: 0, chapterEnd: 1, jobID: UUID().uuidString)
            ])
            XCTAssertThrowsError(try invalid.validate(temporaryRoot: validationRoot), path)
        }
    }

    func testScopeRejectsEmptyCasesInvalidUUIDsAndDuplicateJobs() {
        let spec = specification()
        for invalid in [
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: []),
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: "invalid", wholeBook: false, cases: spec.cases),
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: spec.cases + spec.cases),
            DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false, cases: [
                .init(bookPath: spec.cases[0].bookPath, chapterStart: 0, chapterEnd: 0, jobID: "invalid")
            ])
        ] {
            XCTAssertThrowsError(try invalid.validate(temporaryRoot: validationRoot))
        }
    }

    func testScopeRejectsDuplicateBookPathsWithDistinctJobsAndDisjointRanges() {
        let spec = specification(start: 0, end: 1)
        let duplicate = DeviceBenchmarkSpec.Selection(
            bookPath: spec.cases[0].bookPath, chapterStart: 2, chapterEnd: 3,
            jobID: UUID().uuidString
        )
        XCTAssertNotEqual(spec.cases[0].jobID, duplicate.jobID)
        let invalid = DeviceBenchmarkSpec(schemaVersion: 2, inputBase: "temporary", runID: spec.runID, wholeBook: false,
                                          cases: spec.cases + [duplicate])
        XCTAssertThrowsError(try invalid.validate(temporaryRoot: validationRoot)) { error in
            XCTAssertEqual((error as? BenchmarkFailure)?.description,
                           "Duplicate book path would bypass the per-book chapter cap.")
        }
    }
}
