import Foundation
import Darwin

public final class Workflow {
    public let root: URL
    public let options: Options
    public let runID: String
    public private(set) var report: [String: Any] = [:]
    public let directory: URL
    private let runner: CommandRunner
    private let identity: (Int32) -> String
    private let resourceCheck: () throws -> Void
    private let heavyLock: URL
    private let environment: [String: String]
    private let scopeObserver: ([BenchmarkCase]) -> Void
    private var cases: [BenchmarkCase] = []
    private var timings: [String: Double] = ["deviceWaitSeconds": 0]
    private var staged: String?
    private var started = ProcessInfo.processInfo.systemUptime

    public init(root: URL, options: Options, runID: String = UUID().uuidString,
                runner: @escaping CommandRunner = HostProcess.run,
                identity: @escaping (Int32) -> String = HostProcess.identity,
                resourceCheck: @escaping () throws -> Void = HostProcess.resourceCheck,
                heavyLock: URL = URL(fileURLWithPath: "/tmp/epub2mp3.heavy-job.lock"),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                scopeObserver: @escaping ([BenchmarkCase]) -> Void = { _ in }) {
        self.root = root; self.options = options; self.runID = runID
        self.runner = runner; self.identity = identity; self.resourceCheck = resourceCheck
        self.heavyLock = heavyLock; self.environment = environment
        self.scopeObserver = scopeObserver
        directory = options.reportDirectory.appendingPathComponent(runID)
    }

    public func execute() throws -> [String: Any] {
        if options.action == .status { return try DurableJSON.status(options.state, identity: identity) }
        guard UUID(uuidString: runID) != nil else { throw WorkflowError("Invalid run UUID.") }
        let scopeStart = ProcessInfo.processInfo.systemUptime
        if options.action == .benchmark { cases = try BenchmarkCase.validate(options.rawCases, wholeBook: options.wholeBook, runID: runID) }
        if options.action == .benchmark && !options.preview { scopeObserver(cases) }
        timings["scopeValidationSeconds"] = ProcessInfo.processInfo.systemUptime - scopeStart
        if options.preview { return ["status": "preview", "runID": runID, "wholeBook": options.wholeBook, "cases": cases.map(\.report)] }
        // All mutations, including disk guard and device preparation, are inside both leases.
        let heavy = try FileLease(heavyLock)
        defer { withExtendedLifetime(heavy) {} }
        try FileManager.default.createDirectory(at: options.reportDirectory, withIntermediateDirectories: true)
        let lease = try FileLease(options.reportDirectory.appendingPathComponent("workflow.lock"))
        defer { withExtendedLifetime(lease) {} }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let owner = getpid()
        let ownerIdentity = identity(owner)
        guard !ownerIdentity.isEmpty else { throw WorkflowError("Cannot persist workflow owner start time.") }
        report = ["schemaVersion": 1, "runID": runID, "status": "preflight", "device": options.device,
                  "startedAtUnix": Date().timeIntervalSince1970, "processPid": owner,
                  "processIdentity": ownerIdentity, "cases": cases.map(\.report),
                  "reportPath": directory.appendingPathComponent("report.json").path,
                  "cacheReuse": ["build": options.skipBuild ? "reused" : "incremental", "audio": false, "parsedText": "not_measured"],
                  "nextAction": "Check device readiness."]
        try checkpoint()
        var primary: Error?
        do {
            try resourceCheck()
            try perform()
        } catch {
            primary = error
            report["error"] = String(describing: error)
            if report["status"] as? String != "blocked" { report["status"] = "failed" }
            report["nextAction"] = "Inspect persisted logs/xcresult; retry only explicitly after changed evidence."
        }
        if staged != nil {
            do {
                try cleanupStagedInputs()
            } catch {
                report["cleanupError"] = String(describing: error)
                report["status"] = "failed"
                if primary == nil { primary = error; report["error"] = String(describing: error) }
            }
        }
        report.removeValue(forKey: "childPid")
        report["finishedAtUnix"] = Date().timeIntervalSince1970
        try checkpoint()
        if let primary { throw primary }
        return report
    }

    private func checkpoint() throws {
        timings["totalSeconds"] = ProcessInfo.processInfo.systemUptime - started
        var measured = timings.mapValues { $0 as Any }
        for key in ["preflightSeconds", "buildSeconds", "transferSeconds", "testWallSeconds", "collectionSeconds", "synthesisSeconds", "verificationSeconds"] where measured[key] == nil {
            measured[key] = NSNull()
        }
        report["timings"] = measured
        report["timingNotes"] = "Synthesis and verification overlap testWall; null intervals were not measured. Parsed-text cache reuse is not measured."
        try DurableJSON.write(report, to: directory.appendingPathComponent("report.json"))
        try DurableJSON.write(report, to: options.state)
    }

    @discardableResult
    private func command(_ arguments: [String], _ phase: String, timeout: TimeInterval = 60,
                         check: Bool = true, environment extra: [String: String] = [:]) throws -> CommandResult {
        let start = ProcessInfo.processInfo.systemUptime
        report["phase"] = phase
        let log = directory.appendingPathComponent("\(phase).log")
        report["logPath"] = log.path
        try checkpoint()
        let request = Command(arguments: arguments, environment: extra, directory: root, log: log, timeout: timeout, phase: phase)
        do {
            let result = try runner(request) { pid in
                if let pid { self.report["childPid"] = pid } else { self.report.removeValue(forKey: "childPid") }
                try self.checkpoint()
            }
            timings["\(phase)Seconds"] = ProcessInfo.processInfo.systemUptime - start
            report.removeValue(forKey: "childPid")
            try checkpoint()
            if check && result.code != 0 { throw WorkflowError("\(phase) failed (\(result.code)); inspect \(log.path).") }
            return result
        } catch {
            timings["\(phase)Seconds"] = ProcessInfo.processInfo.systemUptime - start
            report.removeValue(forKey: "childPid")
            try? checkpoint()
            throw error
        }
    }

    private func deviceJSON(_ operation: [String], _ phase: String) throws -> [String: Any] {
        let path = directory.appendingPathComponent("\(phase).json")
        try command(["xcrun", "devicectl", "device"] + operation + ["--device", options.device, "--timeout", "30", "--json-output", path.path], phase)
        let envelope = try DurableJSON.read(path)
        guard (envelope["info"] as? [String: Any])?["outcome"] as? String == "success",
              let result = envelope["result"] as? [String: Any] else { throw WorkflowError("Device query failed: \(phase)") }
        return result
    }

    private func readiness(_ phase: String) throws {
        let lock = try deviceJSON(["info", "lockState"], phase)
        guard lock["passcodeRequired"] as? Bool == false else {
            report["status"] = "blocked"
            throw WorkflowError("Unlock the paired iPhone and explicitly retry; no launch retries are queued.")
        }
    }

    private func perform() throws {
        let preflightStart = ProcessInfo.processInfo.systemUptime
        defer { timings["preflightSeconds"] = timings["preflightSeconds"] ?? ProcessInfo.processInfo.systemUptime - preflightStart }
        try readiness("lockState")
        let details = try deviceJSON(["info", "details"], "details")
        guard let udid = Evidence.find(details, key: "udid") as? String, !udid.isEmpty,
              Evidence.find(details, key: "developerModeStatus") as? String == "enabled" else {
            throw WorkflowError("Device needs a hardware UDID and enabled Developer Mode.")
        }
        report["xcodeDeviceID"] = udid
        timings["preflightSeconds"] = ProcessInfo.processInfo.systemUptime - preflightStart
        if options.action == .preflight {
            report["status"] = "ready"; report["nextAction"] = "Device is ready for an explicit test command."
            return
        }
        let benchmark = options.action == .benchmark
        let project = root.appendingPathComponent("ios/EpubToMp3")
        let products = project.appendingPathComponent(".build/Build/Products")
        let app = products.appendingPathComponent("Debug-iphoneos/EpubToMp3.app")
        let scheme = benchmark ? "EpubToMp3-IntegrationTests" : "EpubToMp3"
        let destination = ["-destination", "platform=iOS,id=\(udid)", "-parallel-testing-enabled", "NO"]
        let common = ["xcodebuild", "-quiet", "-project", project.appendingPathComponent("EpubToMp3.xcodeproj").path,
                      "-scheme", scheme, "-derivedDataPath", project.appendingPathComponent(".build").path] + destination
        let filters = (environment["IOS_TESTS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { "-only-testing:\($0)" }
        report["status"] = "preparing"
        if !options.skipBuild {
            let buildStart = ProcessInfo.processInfo.systemUptime
            report["status"] = "building"
            try command(["bash", root.appendingPathComponent("scripts/ios_disk_guard.sh").path], "diskGuard")
            try command(["xcodegen", "generate", "--spec", project.appendingPathComponent("project.yml").path, "--project", project.path], "projectGeneration")
            try command(["bash", root.appendingPathComponent("scripts/verify_converter_ffi_ios.sh").path], "rustArtifactVerification")
            try command(common + filters + ["build-for-testing"], "build", timeout: 1800)
            timings["buildSeconds"] = ProcessInfo.processInfo.systemUptime - buildStart
        } else { timings["buildSeconds"] = 0 }
        try command(["codesign", "--verify", "--deep", "--strict", app.path], "signing")
        let signing = try command(["codesign", "-dv", "--verbose=2", app.path], "signingIdentity")
        try Evidence.verifyHost(app, identity: signing.output)
        let profile = try command(["security", "cms", "-D", "-i", app.appendingPathComponent("embedded.mobileprovision").path], "provisioning")
        try Evidence.verifyProfile(Data(profile.output.utf8), udid: udid)
        try command(["bash", root.appendingPathComponent("scripts/verify_converter_ffi_ios.sh").path], "embeddedRustVerification",
                    environment: ["CONVERTER_FFI_IOS_ARTIFACT": app.appendingPathComponent("Frameworks/libconverter_ffi.dylib").path])
        var testCommand = common + filters + ["test-without-building"]
        if benchmark {
            let candidates = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix(scheme + "_") && $0.pathExtension == "xctestrun" }
            guard let original = candidates.sorted(by: {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }).first else { throw WorkflowError("No compatible benchmark xctestrun; explicitly retry without --skip-build.") }
            guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: original), format: nil) as? [String: Any] else {
                throw WorkflowError("Invalid xctestrun plist.")
            }
            let spec: [String: Any] = ["schemaVersion": 2, "inputBase": BenchmarkCase.inputBase, "runID": runID, "wholeBook": options.wholeBook, "cases": cases.map(\.specification)]
            let configured = try Evidence.configure(plist, products: products, spec: spec)
            guard let configurations = configured["TestConfigurations"] as? [[String: Any]],
                  let targets = configurations.first?["TestTargets"] as? [[String: Any]],
                  let host = targets.first?["TestHostPath"] as? String,
                  URL(fileURLWithPath: host).standardizedFileURL.resolvingSymlinksInPath() == app.standardizedFileURL.resolvingSymlinksInPath() else {
                throw WorkflowError("xctestrun TestHostPath must be the verified built app.")
            }
            let isolated = directory.appendingPathComponent("benchmark.xctestrun")
            try PropertyListSerialization.data(fromPropertyList: configured, format: .xml, options: 0).write(to: isolated, options: .atomic)
            testCommand = ["xcodebuild", "-quiet", "test-without-building", "-xctestrun", isolated.path] + destination + filters
        }
        try readiness("readinessBeforeTest")
        let processes = try deviceJSON(["info", "processes"], "processes")
        for process in processes["runningProcesses"] as? [[String: Any]] ?? [] {
            guard let executable = process["executable"] as? String, executable.hasSuffix("/EpubToMp3.app/EpubToMp3") else { continue }
            guard let pid = Evidence.integer(process["processIdentifier"]), pid > 0 else { throw WorkflowError("Cannot resolve previous app PID.") }
            try command(["xcrun", "devicectl", "device", "process", "terminate", "--device", options.device, "--pid", String(pid)], "terminatePreviousApp")
        }
        if benchmark {
            try command(["xcrun", "devicectl", "device", "install", "app", "--device", options.device, app.path], "install")
            try stage()
        }
        report["status"] = "testing"
        report["nextAction"] = "Observe the workflow owner; do not restart between child phases."
        let resultBundle = directory.appendingPathComponent("tests.xcresult")
        testCommand += ["-resultBundlePath", resultBundle.path, "-test-timeouts-enabled", "YES",
                        "-default-test-execution-time-allowance", String(options.timeout), "-maximum-test-execution-time-allowance", String(options.timeout)]
        let test = try command(testCommand, "testWall", timeout: TimeInterval(options.timeout + 120), check: false)
        report["status"] = "collecting"
        // Collect evidence even when xcodebuild fails, preserving native conversion diagnostics.
        if benchmark { try collect(resultBundle) }
        let summaryResult = try? command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path], "testSummary", check: false)
        let summary = summaryResult.flatMap { try? JSONSerialization.jsonObject(with: Data($0.output.utf8)) as? [String: Any] }
        if let summary { report["testSummary"] = summary }
        if benchmark, let native = report["nativeEvidence"] as? [String: Any], native["status"] as? String != "passed" {
            throw WorkflowError("Native benchmark failed: \(Evidence.failure(native))")
        }
        guard summaryResult?.code == 0, let summary else {
            throw WorkflowError("Missing/invalid xcresult summary; inspect testSummary.log and testWall.log.")
        }
        try Evidence.verifySummary(summary, benchmark: benchmark)
        guard test.code == 0 else { throw WorkflowError("xcodebuild failed (\(test.code)); inspect testWall.log.") }
        if benchmark {
            guard let native = report["nativeEvidence"] as? [String: Any] else { throw WorkflowError("Native report missing from device and attachments.") }
            timings.merge(try Evidence.verifyNative(native, runID: runID, cases: cases)) { _, new in new }
        }
        report["status"] = "passed"
        report["nextAction"] = "Inspect report.json; no further polling needed."
    }

    private var container: [String] { ["--domain-type", "appDataContainer", "--domain-identifier", Evidence.appID] }

    private func stage() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("epub-device-inputs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (index, selection) in cases.enumerated() {
            try FileManager.default.copyItem(at: selection.source, to: temporary.appendingPathComponent("book-\(index).epub"))
        }
        let copies = try BenchmarkCase.validate(cases.enumerated().map { index, selection in
            [temporary.appendingPathComponent("book-\(index).epub").path, String(selection.start), String(selection.end)]
        }, wholeBook: options.wholeBook, runID: runID)
        guard zip(cases, copies).allSatisfy({ pair in pair.0.digest == pair.1.digest }) else {
            throw WorkflowError("Input changed after scope validation; no staged copies were transferred.")
        }
        // Persist before transfer, which may partially write then fail.
        staged = BenchmarkCase.stagedPath(runID: runID)
        report["stagedInputs"] = staged
        try checkpoint()
        try command(["xcrun", "devicectl", "device", "copy", "to", "--device", options.device] + container + ["--source", temporary.path, "--destination", staged!], "transfer")
    }

    private func collect(_ resultBundle: URL) throws {
        let start = ProcessInfo.processInfo.systemUptime
        defer { timings["collectionSeconds"] = ProcessInfo.processInfo.systemUptime - start }
        let native = directory.appendingPathComponent("native-report.json")
        let result = try? command(["xcrun", "devicectl", "device", "copy", "from", "--device", options.device] + container +
                                 ["--source", BenchmarkCase.reportPath(runID: runID), "--destination", native.path], "nativeCollection", check: false)
        var evidence = result?.code == 0 ? try? DurableJSON.read(native) : nil
        if evidence?["runID"] as? String != runID { evidence = nil }
        if evidence == nil {
            let attachments = directory.appendingPathComponent("attachments")
            _ = try? command(["xcrun", "xcresulttool", "export", "attachments", "--path", resultBundle.path, "--output-path", attachments.path], "attachmentExport", check: false)
            evidence = Evidence.attachment(attachments, runID: runID)
            if let evidence { try DurableJSON.write(evidence, to: native) }
        }
        if let evidence { report["nativeEvidence"] = evidence }
        try checkpoint()
    }

    private func cleanupStagedInputs() throws {
        guard let staged else { return }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("epub-device-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: empty) }
        let result = try command(["xcrun", "devicectl", "device", "copy", "to", "--device", options.device] + container +
                                 ["--source", empty.path, "--destination", staged, "--remove-existing-content", "true"], "inputCleanup", check: false)
        var retained = true
        var emptied = result.code == 0
        if !emptied {
            do {
                let parent = try deviceJSON(["info", "files"] + container + ["--subdirectory", "tmp/EpubToMp3/DeviceTestInputs"], "inputCleanupVerification")
                guard let files = parent["files"] as? [[String: Any]] else { throw WorkflowError("Cannot verify cleanup namespace.") }
                retained = files.contains { $0["name"] as? String == runID }
            } catch {
                // The OS may already have removed the entire temporary namespace.
                // A failed lookup is not proof: require a successful recursive root listing.
                let root = try deviceJSON(["info", "files"] + container + ["--subdirectory", "."], "inputCleanupRootVerification")
                guard let files = root["files"] as? [[String: Any]],
                      files.allSatisfy({ $0["name"] is String }) else {
                    throw WorkflowError("Cannot verify cleanup container root.")
                }
                retained = files.contains {
                    guard let name = $0["name"] as? String else { return true }
                    return name == staged || name.hasPrefix(staged + "/")
                }
                guard !retained else { throw WorkflowError("Staged run remains after failed namespace lookup.") }
            }
            if !retained { emptied = true }
            else {
                let contents = try deviceJSON(["info", "files"] + container + ["--subdirectory", staged], "inputCleanupContents")
                guard let files = contents["files"] as? [[String: Any]] else { throw WorkflowError("Cannot verify staging contents.") }
                emptied = files.isEmpty
            }
        }
        report["cleanup"] = ["stagedInputsEmptied": emptied, "serviceDirectoryRetained": retained ? staged as Any : NSNull()]
        guard emptied else { throw WorkflowError("Cleanup failed; inspect inputCleanup.log before explicit retry.") }
    }
}
