import XCTest
import Foundation
import Darwin
@testable import DeviceWorkflow

final class DeviceWorkflowTests: XCTestCase {
    var root: URL!
    let runID = "E1194183-A751-470A-BE1E-AFB0D1A501F6"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("device-workflow-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func book(_ name: String = "book.epub", content: String = "EPUB fixture bytes") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    func options(_ arguments: [String]) throws -> Options {
        try Options(arguments: arguments, root: root, environment: ["IOS_TESTS": "EpubToMp3Tests/ReaderViewportTransitionTests"])
    }

    func workflow(_ arguments: [String], runner: @escaping CommandRunner,
                          resourceCheck: @escaping () throws -> Void = {},
                          environment: [String: String] = [:]) throws -> Workflow {
        Workflow(root: root, options: try options(arguments), runID: runID, runner: runner,
                 identity: { _ in "Wed Oct 7 12:00:00 2026" }, resourceCheck: resourceCheck,
                 heavyLock: root.appendingPathComponent("heavy.lock"), environment:
                    ["IOS_TESTS": "EpubToMp3Tests/ReaderViewportTransitionTests"].merging(environment) { _, override in override })
    }

    func xctestrun() -> [String: Any] {
        ["__xctestrun_metadata__": ["FormatVersion": 2], "TestConfigurations": [
            ["TestTargets": [
                ["BlueprintName": "Other", "TestHostPath": "other"],
                ["BlueprintName": "EpubToMp3Tests", "TestHostPath": "__TESTROOT__/Debug-iphoneos/EpubToMp3.app",
                 "SkipTestIdentifiers": [Evidence.benchmarkTest], "EnvironmentVariables": ["KEEP": "value"],
                 "DependentProductPaths": ["__TESTROOT__/dependency"]],
            ]], ["TestTargets": [["BlueprintName": "Other"]]],
        ]]
    }

    func native(_ selections: [BenchmarkCase]) -> [String: Any] {
        ["schemaVersion": 1, "runID": runID, "status": "passed", "cases": selections.map { selection -> [String: Any] in
            ["bookPath": selection.bookPath, "chapterStart": selection.start, "chapterEnd": selection.end,
             "chaptersRequested": 2, "chaptersCompleted": 2, "characters": 1000,
             "synthesisSeconds": 10.0, "verificationSeconds": 1.0, "audioDurationSeconds": 12.0,
             "cacheReuse": ["audio": false, "parsedText": "not_measured"]]
        }]
    }

    func appFixture(derivedData: URL? = nil) throws -> URL {
        let products = (derivedData ?? root.appendingPathComponent("ios/EpubToMp3/.build"))
            .appendingPathComponent("Build/Products")
        let app = products.appendingPathComponent("Debug-iphoneos/EpubToMp3.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": Evidence.appID, "CFBundleExecutable": "EpubToMp3"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        try Data("profile".utf8).write(to: app.appendingPathComponent("embedded.mobileprovision"))
        try PropertyListSerialization.data(fromPropertyList: xctestrun(), format: .xml, options: 0)
            .write(to: products.appendingPathComponent("EpubToMp3-IntegrationTests_fixture.xctestrun"))
        return app
    }

    func fakeRunner(phases: NSMutableArray, failNative: Bool = false, cleanupAbsent: Bool = true,
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
                case "appCleanupInspection", "appCleanupRevalidation":
                    result = ["runningProcesses": [["executable": "/apps/EpubToMp3.app/EpubToMp3", "processIdentifier": 42]]]
                case "appCleanupVerification":
                    result = ["runningProcesses": [["executable": "/apps/Unrelated.app/Unrelated", "processIdentifier": 43]]]
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
                XCTAssertTrue(command.arguments.contains("-only-testing:EpubToMp3Tests/ReaderViewportTransitionTests"))
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
                XCTAssertTrue(command.arguments.contains("-only-testing:EpubToMp3Tests/ReaderViewportTransitionTests"))
                XCTAssertEqual(command.arguments[command.arguments.firstIndex(of: "-jobs")! + 1], "1")
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
            case "testSummary":
                let benchmark = (state["cases"] as? [[String: Any]])?.isEmpty == false
                return CommandResult(output: "{\"result\":\"Passed\",\"passedTests\":\(benchmark ? 1 : 4),\"failedTests\":0,\"skippedTests\":0}")
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

    func assertDerivedDataWorkflow(selected: URL, environment: [String: String]) throws {
        let app = try appFixture(derivedData: selected)
        let products = selected.appendingPathComponent("Build/Products")
        let originalRun = products.appendingPathComponent("EpubToMp3-IntegrationTests_fixture.xctestrun")
        let originalBytes = try Data(contentsOf: originalRun)
        let path = try book().path
        for action in ["test", "benchmark"] {
            let fallback = fakeRunner(phases: NSMutableArray())
            var commands: [Command] = []
            let arguments = action == "benchmark" ? [action, "--case", path, "8", "9"] : [action]
            let work = try workflow(arguments, runner: { command, observe in
                commands.append(command)
                return try fallback(command, observe)
            }, environment: environment)
            XCTAssertEqual(try work.execute()["status"] as? String, "passed")
            let build = try XCTUnwrap(commands.first { $0.phase == "build" })
            let buildPath = try XCTUnwrap(build.arguments.firstIndex(of: "-derivedDataPath"))
            XCTAssertEqual(build.arguments[buildPath + 1], selected.path)
            let signing = try XCTUnwrap(commands.first { $0.phase == "signing" })
            XCTAssertEqual(signing.arguments.last, app.path)
            let test = try XCTUnwrap(commands.first { $0.phase == "testWall" })
            if action == "test" {
                let testPath = try XCTUnwrap(test.arguments.firstIndex(of: "-derivedDataPath"))
                XCTAssertEqual(test.arguments[testPath + 1], selected.path)
                XCTAssertTrue(test.arguments.contains("test-without-building"))
            } else {
                let install = try XCTUnwrap(commands.first { $0.phase == "install" })
                XCTAssertEqual(install.arguments.last, app.path)
                let runPath = try XCTUnwrap(test.arguments.firstIndex(of: "-xctestrun"))
                let isolatedRun = URL(fileURLWithPath: test.arguments[runPath + 1])
                let configured = try XCTUnwrap(PropertyListSerialization.propertyList(
                    from: Data(contentsOf: isolatedRun), format: nil) as? [String: Any])
                let configurations = try XCTUnwrap(configured["TestConfigurations"] as? [[String: Any]])
                let targets = try XCTUnwrap(configurations.first?["TestTargets"] as? [[String: Any]])
                XCTAssertEqual(targets.first?["TestHostPath"] as? String, app.path)
                XCTAssertEqual(try Data(contentsOf: originalRun), originalBytes,
                               "Configuring a benchmark must preserve the shared Xcode fixture")
            }
            try FileManager.default.removeItem(at: work.directory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            root.appendingPathComponent("ios/EpubToMp3/.build").path),
            "A shared-cache workflow must not silently create a second app cache")
    }

    func profile() -> [String: Any] {
        ["ExpirationDate": Date().addingTimeInterval(3600), "TeamIdentifier": ["TEAM"],
         "Entitlements": ["application-identifier": "TEAM." + Evidence.appID], "ProvisionedDevices": ["hardware-udid"]]
    }

}
