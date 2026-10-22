import XCTest
import Foundation
import Darwin
@testable import DeviceWorkflow

extension DeviceWorkflowTests {
    func testCleanupRefusesReplacedPIDAndRetainsTestFailure() throws {
        _ = try appFixture()
        let fallback = fakeRunner(phases: NSMutableArray())
        var terminated = false
        let work = try workflow(["test"], runner: { command, observe in
            if command.phase == "testWall" {
                _ = try fallback(command, observe)
                throw WorkflowError("original test failure")
            }
            if command.phase == "appCleanupTermination" { terminated = true }
            if command.phase == "appCleanupRevalidation" {
                let path = command.arguments[command.arguments.firstIndex(of: "--json-output")! + 1]
                try DurableJSON.write(["info": ["outcome": "success"], "result": ["runningProcesses": [
                    ["executable": "/apps/EpubToMp3.app/EpubToMp3", "processIdentifier": 99]
                ]]], to: URL(fileURLWithPath: path))
                return CommandResult()
            }
            return try fallback(command, observe)
        })
        XCTAssertThrowsError(try work.execute()) { XCTAssertTrue(String(describing: $0).contains("original test failure")) }
        XCTAssertFalse(terminated)
        XCTAssertEqual(work.report["appCleanupVerified"] as? Bool, false)
        XCTAssertTrue((work.report["appCleanupError"] as? String ?? "").contains("identity changed"))
    }

    func testNoCleanupDeviceActionsWhenTestSpawnWasRefused() throws {
        _ = try appFixture()
        let fallback = fakeRunner(phases: NSMutableArray())
        let work = try workflow(["test"], runner: { command, observe in
            XCTAssertFalse(command.phase.hasPrefix("appCleanup"))
            if command.phase == "testWall" { throw WorkflowError("spawn refused") }
            return try fallback(command, observe)
        })
        XCTAssertThrowsError(try work.execute())
        XCTAssertNil(work.report["appCleanupVerified"])
    }

    func testPartialOrSkippedFocusedRunCannotPassAndStillCleansUp() throws {
        _ = try appFixture()
        for (index, counts) in [(1, 0), (3, 1)].enumerated() {
            let fallback = fakeRunner(phases: NSMutableArray())
            let work = try workflow(["test"], runner: { command, observe in
                if command.phase == "testSummary" {
                    return CommandResult(output: "{\"result\":\"Passed\",\"passedTests\":\(counts.0),\"failedTests\":0,\"skippedTests\":\(counts.1)}")
                }
                return try fallback(command, observe)
            })
            XCTAssertThrowsError(try work.execute(), "case \(index)")
            XCTAssertEqual(work.report["appCleanupVerified"] as? Bool, true)
            try FileManager.default.removeItem(at: work.directory)
        }
    }

    func testCleanupDoesNotClaimSuccessForInvalidInventoryOrRemainingApp() throws {
        _ = try appFixture()
        for invalidInventory in [true, false] {
            let fallback = fakeRunner(phases: NSMutableArray())
            let work = try workflow(["test"], runner: { command, observe in
                if command.phase == "appCleanupVerification" {
                    let result: [String: Any] = invalidInventory ? [:] : ["runningProcesses": [
                        ["executable": "/apps/EpubToMp3.app/EpubToMp3", "processIdentifier": 42]
                    ]]
                    let path = command.arguments[command.arguments.firstIndex(of: "--json-output")! + 1]
                    try DurableJSON.write(["info": ["outcome": "success"], "result": result], to: URL(fileURLWithPath: path))
                    return CommandResult()
                }
                return try fallback(command, observe)
            })
            XCTAssertThrowsError(try work.execute())
            XCTAssertEqual(work.report["appCleanupVerified"] as? Bool, false)
            XCTAssertEqual(work.report["status"] as? String, "failed")
            try FileManager.default.removeItem(at: work.directory)
        }
    }

    func testWrongTestHostFailsBeforeDeviceWrites() throws {
        _ = try appFixture()
        let path = try book().path
        var original = xctestrun()
        original["TestConfigurations"] = [["TestTargets": [["BlueprintName": "EpubToMp3Tests", "TestHostPath": "/another/App.app"]]]]
        let products = root.appendingPathComponent("ios/EpubToMp3/.build/Build/Products")
        try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0)
            .write(to: products.appendingPathComponent("EpubToMp3-IntegrationTests_fixture.xctestrun"))
        let phases = NSMutableArray()
        let work = try workflow(["benchmark", "--skip-build", "--case", path, "8", "9"], runner: fakeRunner(phases: phases))
        XCTAssertThrowsError(try work.execute())
        let executed = phases as? [String] ?? []
        XCTAssertFalse(executed.contains("terminatePreviousApp"))
        XCTAssertFalse(executed.contains("install"))
        XCTAssertFalse(executed.contains("transfer"))
    }

    func testBenchmarkAttachmentFallbackAndCleanupPostResponseError() throws {
        _ = try appFixture()
        let path = try book().path
        let phases = NSMutableArray()
        let work = try workflow(["benchmark", "--skip-build", "--case", path, "8", "9"], runner: fakeRunner(phases: phases))
        let report = try work.execute()
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual((report["cleanup"] as? [String: Any])?["stagedInputsEmptied"] as? Bool, true)
        XCTAssertTrue((report["cleanup"] as? [String: Any])?["serviceDirectoryRetained"] is NSNull)
        XCTAssertEqual((phases as? [String])?.filter { $0 == "inputCleanup" }.count, 1)
        XCTAssertNil(report["childPid"])
        XCTAssertEqual((report["timings"] as? [String: Double])?["synthesisSeconds"], 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.directory.appendingPathComponent("native-report.json").path))
    }

    func testTwoBookTemporaryPathsPreserveExactChapterRanges() throws {
        let first = try book()
        let second = try book("second.epub", content: "Distinct second EPUB fixture")
        let work = try workflow(["benchmark", "--preview", "--case", first.path, "8", "9",
                                 "--case", second.path, "6", "7"], runner: { _, _ in
            XCTFail("Preview must not invoke Apple tools")
            return CommandResult()
        })
        let cases = try XCTUnwrap(try work.execute()["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 2)
        for (index, bounds) in [[8, 9], [6, 7]].enumerated() {
            XCTAssertEqual(cases[index]["bookPath"] as? String,
                           "EpubToMp3/DeviceTestInputs/\(runID)/book-\(index).epub")
            XCTAssertEqual(cases[index]["chapterStart"] as? Int, bounds[0])
            XCTAssertEqual(cases[index]["chapterEnd"] as? Int, bounds[1])
        }
    }

    func testCleanupMissingParentRequiresReadableRootWithoutStagedRun() throws {
        _ = try appFixture()
        let path = try book().path
        for state in ["absent", "retained", "unreadable"] {
            let fallback = fakeRunner(phases: NSMutableArray())
            var queriedRoot = false
            let work = try workflow(["benchmark", "--skip-build", "--case", path, "8", "9"], runner: { command, observe in
                if command.phase == "inputCleanupVerification" { return CommandResult(code: 1) }
                if command.phase == "inputCleanupRootVerification" {
                    queriedRoot = true
                    XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--subdirectory")! + 1], ".")
                    if state == "unreadable" { return CommandResult(code: 1) }
                    let names = state == "retained"
                        ? ["tmp", "tmp/EpubToMp3/DeviceTestInputs/\(self.runID)/book-0.epub"] : ["tmp"]
                    let destination = command.arguments[command.arguments.firstIndex(of: "--json-output")! + 1]
                    try DurableJSON.write(["info": ["outcome": "success"],
                                           "result": ["files": names.map { ["name": $0] }]],
                                          to: URL(fileURLWithPath: destination))
                    return CommandResult()
                }
                return try fallback(command, observe)
            })
            // Each mocked workflow owns an exclusive run directory.
            defer { try? FileManager.default.removeItem(at: work.directory) }
            if state == "absent" {
                XCTAssertEqual(try work.execute()["status"] as? String, "passed")
            } else {
                XCTAssertThrowsError(try work.execute())
            }
            XCTAssertTrue(queriedRoot, "Must verify root rather than assume a missing parent means cleanup succeeded")
        }
    }

    func testTemporaryNativeReportCollectionAvoidsAttachmentExport() throws {
        _ = try appFixture()
        let path = try book().path
        let phases = NSMutableArray()
        let fallback = fakeRunner(phases: phases)
        let work = try workflow(["benchmark", "--skip-build", "--case", path, "8", "9"], runner: { command, observe in
            if command.phase == "nativeCollection" {
                phases.add(command.phase)
                XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--source")! + 1],
                               "tmp/DeviceBenchmarkReports/\(self.runID).json")
                let selections = try BenchmarkCase.validate([[path, "8", "9"]], wholeBook: false, runID: self.runID)
                let destination = command.arguments[command.arguments.firstIndex(of: "--destination")! + 1]
                try DurableJSON.write(self.native(selections), to: URL(fileURLWithPath: destination))
                return CommandResult()
            }
            return try fallback(command, observe)
        })
        XCTAssertEqual(try work.execute()["status"] as? String, "passed")
        XCTAssertFalse((phases as? [String] ?? []).contains("attachmentExport"))
    }

    func testPrimaryRustFailureSurvivesCleanupFailure() throws {
        _ = try appFixture()
        let path = try book().path
        let phases = NSMutableArray()
        let work = try workflow(["benchmark", "--skip-build", "--case", path, "8", "9"],
                                runner: fakeRunner(phases: phases, failNative: true, cleanupAbsent: false))
        XCTAssertThrowsError(try work.execute()) { XCTAssertTrue(String(describing: $0).contains("OS error 2")) }
        XCTAssertTrue((work.report["error"] as? String ?? "").contains("OS error 2"))
        XCTAssertNotNil(work.report["cleanupError"])
        XCTAssertEqual(work.report["status"] as? String, "failed")
    }

    func testNativeResourceRejectionRunsNoCommands() throws {
        let work = try workflow(["test"], runner: { _, _ in XCTFail("Resource failure invoked command"); return CommandResult() },
                                resourceCheck: { throw WorkflowError("Host load exceeds 6") })
        XCTAssertThrowsError(try work.execute())
        XCTAssertEqual(work.report["status"] as? String, "failed")
    }
}
