import XCTest
import Foundation
import Darwin
@testable import DeviceWorkflow

final class DeviceWorkflowTests: XCTestCase {
    private var root: URL!
    private let runID = "E1194183-A751-470A-BE1E-AFB0D1A501F6"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("device-workflow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func book(_ name: String = "book.epub", content: String = "EPUB fixture bytes") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func options(_ arguments: [String]) throws -> Options {
        try Options(arguments: arguments, root: root, environment: [:])
    }

    private func workflow(_ arguments: [String], runner: @escaping CommandRunner,
                          resourceCheck: @escaping () throws -> Void = {}) throws -> Workflow {
        Workflow(root: root, options: try options(arguments), runID: runID, runner: runner,
                 identity: { _ in "Wed Oct 7 12:00:00 2026" }, resourceCheck: resourceCheck,
                 heavyLock: root.appendingPathComponent("heavy.lock"), environment: ["IOS_TESTS": "EpubToMp3Tests/Smoke"])
    }

    func testScopeLimitsSentinelsOverflowAndMissingInput() throws {
        let path = try book().path
        for bounds in [["0", "2"], ["-1", "1"], ["1", "0"], ["-1", "-1"], ["2147483648", "2147483648"], ["999999999999999999999999", "0"], ["x", "1"]] {
            XCTAssertThrowsError(try BenchmarkCase.validate([[path] + bounds], wholeBook: false, runID: runID))
        }
        XCTAssertThrowsError(try BenchmarkCase.validate([], wholeBook: false, runID: runID))
        XCTAssertThrowsError(try BenchmarkCase.validate([[path]], wholeBook: false, runID: runID))
        XCTAssertThrowsError(try BenchmarkCase.validate([[root.appendingPathComponent("missing.epub").path, "0", "0"]], wholeBook: false, runID: runID))
        XCTAssertThrowsError(try BenchmarkCase.validate([[root.path, "0", "0"]], wholeBook: false, runID: runID))
        XCTAssertEqual(try BenchmarkCase.validate([[path, "8", "9"]], wholeBook: false, runID: runID).first?.end, 9)
        XCTAssertEqual(try BenchmarkCase.validate([[path, "-1", "-1"]], wholeBook: true, runID: runID).first?.start, -1)
        XCTAssertThrowsError(try BenchmarkCase.validate([[path, "0", "3"]], wholeBook: true, runID: runID))
    }

    func testCopiesAndHardLinksAreDuplicateContent() throws {
        let original = try book()
        let copy = root.appendingPathComponent("copy.epub")
        let hardlink = root.appendingPathComponent("hardlink.epub")
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.linkItem(at: original, to: hardlink)
        for other in [copy, hardlink, original] {
            XCTAssertThrowsError(try BenchmarkCase.validate([[original.path, "0", "0"], [other.path, "1", "1"]], wholeBook: false, runID: runID))
        }
    }

    func testValidatedScopeIsDisplayedBeforeAnyDeviceCommand() throws {
        let path = try book().path
        let selected = try options(["benchmark", "--case", path, "8", "9"])
        var observed: [[BenchmarkCase]] = []
        let subject = Workflow(root: root, options: selected, runID: runID,
            runner: { _, _ in XCTFail("Scope display must precede device commands"); return CommandResult() },
            identity: { _ in "stable owner start" },
            resourceCheck: { throw WorkflowError("Stop after scope display") },
            heavyLock: root.appendingPathComponent("heavy.lock"), environment: [:],
            scopeObserver: { observed.append($0) })
        XCTAssertThrowsError(try subject.execute())
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.first?.start, 8)
        XCTAssertEqual(observed.first?.first?.end, 9)
    }

    func testPreviewDoesNotAcquireLockWriteReportOrRunCommands() throws {
        let path = try book().path
        let lease = try FileLease(root.appendingPathComponent("heavy.lock"))
        defer { withExtendedLifetime(lease) {} }
        let work = try workflow(["benchmark", "--preview", "--case", path, "8", "9"], runner: { _, _ in
            XCTFail("Preview invoked a command"); return CommandResult()
        }, resourceCheck: { XCTFail("Preview inspected host resources") })
        XCTAssertEqual(try work.execute()["status"] as? String, "preview")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".reports").path))
    }

    func testBusySharedLockStartsNoActions() throws {
        let lease = try FileLease(root.appendingPathComponent("heavy.lock"))
        defer { withExtendedLifetime(lease) {} }
        let work = try workflow(["test"], runner: { _, _ in XCTFail("Busy lock invoked a command"); return CommandResult() })
        XCTAssertThrowsError(try work.execute())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".reports").path))
    }

    func testInvalidScopeStartsNoActionsOrReports() throws {
        let work = try workflow(["benchmark", "--case", try book().path, "0", "2"], runner: { _, _ in
            XCTFail("Invalid scope invoked command"); return CommandResult()
        })
        XCTAssertThrowsError(try work.execute())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".reports").path))
    }

    func testParserRejectsMissingBoundsAndOverflowTimeout() throws {
        XCTAssertThrowsError(try options(["benchmark", "--case", "book.epub", "0"]))
        XCTAssertThrowsError(try options(["test", "--timeout", "9999999999999999999999"]))
        XCTAssertThrowsError(try options(["test", "--preview"]))
        XCTAssertThrowsError(try options(["test", "--state", "state.json"]))
        let parsed = try options(["status", "--report-dir", root.path])
        XCTAssertEqual(parsed.state.path, root.appendingPathComponent("latest.json").path)
    }

    func testSecondaryLeasePreservesLatest() throws {
        let reportDirectory = root.appendingPathComponent(".reports/device")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let latest = reportDirectory.appendingPathComponent("latest.json")
        try DurableJSON.write(["status": "existing"], to: latest)
        let lease = try FileLease(reportDirectory.appendingPathComponent("workflow.lock"))
        defer { withExtendedLifetime(lease) {} }
        let work = try workflow(["test"], runner: { _, _ in XCTFail("Busy lease invoked command"); return CommandResult() })
        XCTAssertThrowsError(try work.execute())
        XCTAssertEqual(try DurableJSON.read(latest)["status"] as? String, "existing")
    }

    func testStatusChecksOnlyOwnerStartTimeOnce() throws {
        let state = root.appendingPathComponent("state.json")
        try DurableJSON.write(["processPid": 123, "childPid": 999, "processIdentity": "start", "status": "testing"], to: state)
        var calls: [Int32] = []
        let live = try DurableJSON.status(state) { calls.append($0); return "start" }
        XCTAssertEqual(calls, [123])
        XCTAssertEqual(live["processLive"] as? Bool, true)
        let stale = try DurableJSON.status(state) { _ in "different start" }
        XCTAssertEqual(stale["processLive"] as? Bool, false)
        XCTAssertTrue((stale["nextAction"] as? String ?? "").contains("inspect"))
        XCTAssertEqual(try DurableJSON.read(state)["status"] as? String, "testing")
    }

    func testDurableReplacementAndNoTemporaryCheckpoint() throws {
        let path = root.appendingPathComponent("reports/state.json")
        try DurableJSON.write(["phase": "build"], to: path)
        try DurableJSON.write(["phase": "collection"], to: path)
        XCTAssertEqual(try DurableJSON.read(path)["phase"] as? String, "collection")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path), ["state.json"])
    }

    private func xctestrun() -> [String: Any] {
        ["__xctestrun_metadata__": ["FormatVersion": 2], "TestConfigurations": [
            ["TestTargets": [
                ["BlueprintName": "Other", "TestHostPath": "other"],
                ["BlueprintName": "EpubToMp3Tests", "TestHostPath": "__TESTROOT__/Debug-iphoneos/EpubToMp3.app",
                 "SkipTestIdentifiers": [Evidence.benchmarkTest], "EnvironmentVariables": ["KEEP": "value"],
                 "DependentProductPaths": ["__TESTROOT__/dependency"]],
            ]], ["TestTargets": [["BlueprintName": "Other"]]],
        ]]
    }

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

    private func native(_ selections: [BenchmarkCase]) -> [String: Any] {
        ["schemaVersion": 1, "runID": runID, "status": "passed", "cases": selections.map { selection -> [String: Any] in
            ["bookPath": selection.bookPath, "chapterStart": selection.start, "chapterEnd": selection.end,
             "chaptersRequested": 2, "chaptersCompleted": 2, "characters": 1000,
             "synthesisSeconds": 10.0, "verificationSeconds": 1.0, "audioDurationSeconds": 12.0,
             "cacheReuse": ["audio": false, "parsedText": "not_measured"]]
        }]
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

    private func appFixture() throws -> URL {
        let products = root.appendingPathComponent("ios/EpubToMp3/.build/Build/Products")
        let app = products.appendingPathComponent("Debug-iphoneos/EpubToMp3.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": Evidence.appID, "CFBundleExecutable": "EpubToMp3"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("profile".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        try PropertyListSerialization.data(fromPropertyList: xctestrun(), format: .xml, options: 0)
            .write(to: products.appendingPathComponent("EpubToMp3-IntegrationTests_fixture.xctestrun"))
        return app
    }

    func testSigningRejectsAdHocWrongIDAndMissingProfile() throws {
        let app = try appFixture()
        XCTAssertThrowsError(try Evidence.verifyHost(app, identity: "Signature=adhoc"))
        try Evidence.verifyHost(app, identity: "Authority=Apple Development: Fixture")
        try FileManager.default.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))
        XCTAssertThrowsError(try Evidence.verifyHost(app, identity: "Authority=Apple Distribution: Fixture"))
        try Data("profile".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        let wrong = ["CFBundleIdentifier": "other.app", "CFBundleExecutable": "EpubToMp3"]
        try PropertyListSerialization.data(fromPropertyList: wrong, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try Evidence.verifyHost(app, identity: "Authority=Apple Development: Fixture"))
    }

    // Apple tooling is replaced at the command boundary, not by parsing production sources.
    private func fakeRunner(phases: NSMutableArray, failNative: Bool = false, cleanupAbsent: Bool = true,
                            locked: Bool = false) -> CommandRunner {
        { command, observe in
            phases.add(command.phase)
            XCTAssertThrowsError(try FileLease(self.root.appendingPathComponent("heavy.lock")))
            XCTAssertThrowsError(try FileLease(self.root.appendingPathComponent(".reports/device/workflow.lock")))
            XCTAssertFalse(command.arguments.contains { $0.contains(".py") || $0 == "python" || $0 == "ruff" })
            XCTAssertFalse(command.arguments.contains { $0.contains("Library/Application Support") })
            try observe(4321)
            let state = try DurableJSON.read(self.root.appendingPathComponent(".reports/device/latest.json"))
            XCTAssertEqual((state["processPid"] as? NSNumber)?.int32Value, getpid())
            XCTAssertEqual((state["childPid"] as? NSNumber)?.intValue, 4321)
            if let outputIndex = command.arguments.firstIndex(of: "--json-output") {
                var result: [String: Any] = [:]
                switch command.phase {
                case "lockState", "readinessBeforeTest": result = ["passcodeRequired": locked]
                case "details": result = ["hardware": ["udid": "hardware-udid"], "developerModeStatus": "enabled"]
                case "processes": result = ["runningProcesses": [
                    ["executable": "/apps/EpubToMp3.app/EpubToMp3", "processIdentifier": 42],
                    ["executable": "/apps/EpubToMp3.app/Other", "processIdentifier": 43],
                ]]
                case "inputCleanupVerification":
                    XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--subdirectory")! + 1],
                                   "tmp/EpubToMp3/DeviceTestInputs")
                    result = ["files": cleanupAbsent ? [] : [["name": self.runID]]]
                case "inputCleanupContents":
                    XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--subdirectory")! + 1],
                                   "tmp/EpubToMp3/DeviceTestInputs/\(self.runID)")
                    result = ["files": [["name": "book-0.epub"]]]
                default: XCTFail("Unexpected JSON query: \(command.phase)")
                }
                try DurableJSON.write(["info": ["outcome": "success"], "result": result], to: URL(fileURLWithPath: command.arguments[outputIndex + 1]))
            }
            try observe(nil)
            switch command.phase {
            case "signingIdentity": return CommandResult(output: "Authority=Apple Development: Fixture")
            case "provisioning":
                let data = try PropertyListSerialization.data(fromPropertyList: self.profile(), format: .xml, options: 0)
                return CommandResult(output: String(decoding: data, as: UTF8.self))
            case "embeddedRustVerification":
                XCTAssertTrue(command.environment["CONVERTER_FFI_IOS_ARTIFACT"]!.hasSuffix("EpubToMp3.app/Frameworks/libconverter_ffi.dylib"))
            case "terminatePreviousApp": XCTAssertEqual(command.arguments.last, "42")
            case "transfer":
                let index = command.arguments.firstIndex(of: "--source")!
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: command.arguments[index + 1]), ["book-0.epub"])
                XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--destination")! + 1],
                               "tmp/EpubToMp3/DeviceTestInputs/\(self.runID)")
            case "testWall":
                XCTAssertTrue(command.arguments.contains("-only-testing:EpubToMp3Tests/Smoke"))
                if let index = command.arguments.firstIndex(of: "-xctestrun") {
                    let plist = try PropertyListSerialization.propertyList(
                        from: Data(contentsOf: URL(fileURLWithPath: command.arguments[index + 1])), format: nil) as! [String: Any]
                    let configurations = plist["TestConfigurations"] as! [[String: Any]]
                    let target = (configurations[0]["TestTargets"] as! [[String: Any]])[0]
                    let environment = target["EnvironmentVariables"] as! [String: String]
                    let spec = try JSONSerialization.jsonObject(with: Data(environment["EPUB2MP3_DEVICE_BENCHMARK_SPEC"]!.utf8)) as! [String: Any]
                    XCTAssertEqual(spec["schemaVersion"] as? Int, 2)
                    XCTAssertEqual(spec["inputBase"] as? String, "temporary")
                    let cases = spec["cases"] as! [[String: Any]]
                    XCTAssertEqual(cases[0]["bookPath"] as? String,
                                   "EpubToMp3/DeviceTestInputs/\(self.runID)/book-0.epub")
                    XCTAssertEqual(cases[0]["chapterStart"] as? Int, 8)
                    XCTAssertEqual(cases[0]["chapterEnd"] as? Int, 9)
                }
                return CommandResult(code: failNative ? 65 : 0)
            case "build":
                XCTAssertTrue(command.arguments.contains("-only-testing:EpubToMp3Tests/Smoke"))
                XCTAssertTrue(command.arguments.contains("build-for-testing"))
            case "nativeCollection":
                XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--source")! + 1],
                               "tmp/DeviceBenchmarkReports/\(self.runID).json")
                return CommandResult(code: 1)
            case "attachmentExport":
                let index = command.arguments.firstIndex(of: "--output-path")!
                let selections = try BenchmarkCase.validate([[self.root.appendingPathComponent("book.epub").path, "8", "9"]], wholeBook: false, runID: self.runID)
                var evidence = self.native(selections)
                if failNative { evidence["status"] = "failed"; evidence["error"] = "ffprobe/ffmpeg: No such file (os error 2)" }
                try DurableJSON.write(evidence, to: URL(fileURLWithPath: command.arguments[index + 1]).appendingPathComponent("native.json"))
            case "testSummary": return CommandResult(output: "{\"result\":\"Passed\",\"passedTests\":1,\"failedTests\":0,\"skippedTests\":0}")
            case "inputCleanup":
                XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "--destination")! + 1],
                               "tmp/EpubToMp3/DeviceTestInputs/\(self.runID)")
                XCTAssertEqual(Array(command.arguments.suffix(2)), ["--remove-existing-content", "true"])
                return CommandResult(code: 1, output: "CoreDevice error 7000: missing node")
            default: break
            }
            return CommandResult()
        }
    }

    func testLockedDeviceFailsBeforeBuildAndWrites() throws {
        let phases = NSMutableArray()
        let work = try workflow(["test"], runner: fakeRunner(phases: phases, locked: true))
        XCTAssertThrowsError(try work.execute())
        XCTAssertEqual(phases as? [String], ["lockState"])
        XCTAssertEqual(work.report["status"] as? String, "blocked")
    }

    func testBuildAndGeneralTestShareCacheFiltersAndLock() throws {
        _ = try appFixture()
        let phases = NSMutableArray()
        let work = try workflow(["test"], runner: fakeRunner(phases: phases))
        XCTAssertEqual(try work.execute()["status"] as? String, "passed")
        let executed = phases as? [String] ?? []
        XCTAssertTrue(executed.contains("build"))
        XCTAssertTrue(executed.contains("diskGuard"))
        XCTAssertTrue(executed.contains("projectGeneration"))
        XCTAssertFalse(executed.contains("install"))
        XCTAssertFalse(executed.contains("transfer"))
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

    func testOwnedProcessGroupAndTimeoutReap() throws {
        let log = root.appendingPathComponent("process.log")
        var child: Int32?
        var observations: [Int32?] = []
        let request = Command(arguments: ["/bin/sh", "-c", "sleep 10 & wait"], directory: root, log: log, timeout: 0.1, phase: "timeout")
        XCTAssertThrowsError(try HostProcess.run(request) { pid in
            observations.append(pid)
            if let pid { child = pid; XCTAssertEqual(getpgid(pid), pid) }
        })
        XCTAssertEqual(observations.count, 2)
        XCTAssertNil(observations.last!)
        let pid = try XCTUnwrap(child)
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testSubprocessCapturesOutputAndNonzeroExit() throws {
        let request = Command(arguments: ["/bin/sh", "-c", "printf evidence; exit 7"], directory: root,
                              log: root.appendingPathComponent("output.log"), timeout: 2, phase: "fixture")
        let result = try HostProcess.run(request) { _ in }
        XCTAssertEqual(result.code, 7)
        XCTAssertEqual(result.output, "evidence")
    }

    private func profile() -> [String: Any] {
        ["ExpirationDate": Date().addingTimeInterval(3600), "TeamIdentifier": ["TEAM"],
         "Entitlements": ["application-identifier": "TEAM." + Evidence.appID], "ProvisionedDevices": ["hardware-udid"]]
    }

    func testProvisioningRejectsExpiredWrongBundleAndWrongDevice() throws {
        func encoded(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        try Evidence.verifyProfile(encoded(profile()), udid: "hardware-udid")
        XCTAssertThrowsError(try Evidence.verifyProfile(encoded(profile()), udid: "another-device"))
        var expired = profile(); expired["ExpirationDate"] = Date().addingTimeInterval(-3600)
        XCTAssertThrowsError(try Evidence.verifyProfile(encoded(expired), udid: "hardware-udid"))
        var wrong = profile(); wrong["Entitlements"] = ["application-identifier": "TEAM.other"]
        XCTAssertThrowsError(try Evidence.verifyProfile(encoded(wrong), udid: "hardware-udid"))
    }
}
