import XCTest
import Foundation
import Darwin
@testable import DeviceWorkflow

extension DeviceWorkflowTests {
    func testVersionTwoIsolationPreservesEnvironmentAndOriginal() throws {
        let original = xctestrun()
        let configured = try Evidence.configure(original, products: root, spec: ["runID": runID])
        let configurations = try XCTUnwrap(configured["TestConfigurations"] as? [[String: Any]])
        XCTAssertEqual(configurations.count, 1)
        let targets = try XCTUnwrap(configurations[0]["TestTargets"] as? [[String: Any]])
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets[0]["OnlyTestIdentifiers"] as? [String], [Evidence.benchmarkTest])
        XCTAssertNil(targets[0]["SkipTestIdentifiers"])
        XCTAssertEqual(targets[0]["TestHostPath"] as? String, root.path + "/Debug-iphoneos/EpubToMp3.app")
        let environment = try XCTUnwrap(targets[0]["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["KEEP"], "value")
        XCTAssertTrue(environment["EPUB2MP3_DEVICE_BENCHMARK_SPEC"]!.contains(runID))
        XCTAssertEqual((original["TestConfigurations"] as? [[String: Any]])?.count, 2)
        XCTAssertThrowsError(try Evidence.configure(["TestConfigurations": []], products: root, spec: [:]))
    }

    func testSummaryRejectsAllSkippedZeroPassAndWrongCounts() throws {
        let summaries: [[String: Any]] = [
            ["result": "Passed", "passedTests": 0, "failedTests": 0, "skippedTests": 1],
            ["result": "Passed", "passedTests": 1, "failedTests": 0, "skippedTests": 1],
            ["result": "Passed", "passedTests": 2, "failedTests": 0, "skippedTests": 0],
            ["result": "Passed", "passedTests": true, "failedTests": 0, "skippedTests": 0],
        ]
        for summary in summaries { XCTAssertThrowsError(try Evidence.verifySummary(summary, benchmark: true)) }
        try Evidence.verifySummary(["result": "Passed", "passedTests": 1, "failedTests": 0, "skippedTests": 0], benchmark: true)
    }

    func testNativeScopeCountsAudioAndUnknownCacheEvidence() throws {
        let selections = try BenchmarkCase.validate([[try book().path, "8", "9"]], wholeBook: false, runID: runID)
        let good = native(selections)
        XCTAssertEqual(try Evidence.verifyNative(good, runID: runID, cases: selections)["synthesisSeconds"], 10)
        let changes: [(String, Any)] = [("chapterEnd", 10), ("chaptersCompleted", 1), ("audioDurationSeconds", 0), ("cacheReuse", ["audio": true, "parsedText": "not_measured"])]
        for (key, value) in changes {
            var bad = good
            var actual = bad["cases"] as! [[String: Any]]
            actual[0][key] = value; bad["cases"] = actual
            XCTAssertThrowsError(try Evidence.verifyNative(bad, runID: runID, cases: selections))
        }
    }
}
