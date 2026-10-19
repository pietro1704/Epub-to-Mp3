import Foundation
import Darwin

let environment = ProcessInfo.processInfo.environment
guard let operationSeconds = Double(environment["IOS_SIMULATOR_OPERATION_TIMEOUT"] ?? "300"),
      operationSeconds >= 30, operationSeconds <= 1200 else { exit(2) }
guard let identifier = environment["IOS_SIMULATOR_UDID"], UUID(uuidString: identifier) != nil,
      let mode = CommandLine.arguments.dropFirst().first, ["build", "test"].contains(mode)
else { fputs("Specify Simulator UUID and operation.\n", stderr); exit(2) }
let lease = open("/tmp/epub2mp3.heavy-job.lock", O_CREAT | O_RDWR, 0o600)
guard lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0 else { exit(75) }
defer { close(lease) }
func run(_ arguments: [String], capture: Bool = false) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let pipe = Pipe()
    if capture { process.standardOutput = pipe }
    try process.run()
    let operationDeadline = Date().addingTimeInterval(operationSeconds)
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    if mode == "test" && !capture {
        while process.isRunning {
            Thread.sleep(forTimeInterval: 1)
            if Date() > operationDeadline {
                fputs("Stopping Simulator operation: time budget exceeded.\n", stderr)
                process.terminate()
                process.waitUntilExit()
                let shutdown = Process()
                shutdown.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                shutdown.arguments = ["simctl", "shutdown", identifier]
                try shutdown.run(); shutdown.waitUntilExit()
                exit(75)
            }
        }
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return data
}
let deviceData = try run(["simctl", "list", "devices", "booted", "-j"], capture: true)
let json = try JSONSerialization.jsonObject(with: deviceData) as? [String: Any]
guard let devices = json?["devices"] as? [String: [[String: Any]]] else { exit(2) }
let booted = devices.values.flatMap { $0 }
guard booted.isEmpty || (mode == "test" && booted.count == 1 && booted[0]["udid"] as? String == identifier)
else { fputs("Stop other Simulators; builds require all Simulators stopped.\n", stderr); exit(75) }
let root = environment["MISE_PROJECT_ROOT"] ?? FileManager.default.currentDirectoryPath
let report = URL(fileURLWithPath: root).appendingPathComponent(".reports/simulator-smoke-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
print("Evidence: \(report.path)")
let selections = environment["IOS_TESTS"]?.split(separator: ",").map(String.init)
    ?? ["EpubToMp3Tests/BundledConverterFFISmokeTests",
        "EpubToMp3UITests/LibrarySearchUITests/testSearchBarFiltersAndClears"]
guard !selections.isEmpty, selections.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }) else { exit(2) }
let filters = selections.map { "-only-testing:\($0)" }
let project = environment["IOS_SIMULATOR_PROJECT_PATH"] ?? root + "/ios/EpubToMp3/EpubToMp3.xcodeproj"
let scheme = environment["IOS_SIMULATOR_SCHEME"] ?? "EpubToMp3"
var arguments = ["xcodebuild", "-quiet", "-project", project,
                 "-scheme", scheme, "-configuration", "Debug", "-jobs", "1",
                 "-parallel-testing-enabled", "NO", "-derivedDataPath", root + "/ios/EpubToMp3/.build",
                 "-resultBundlePath", report.appendingPathComponent("tests.xcresult").path] + filters
if mode == "build" {
    arguments += ["-destination", "generic/platform=iOS Simulator", "build-for-testing"]
} else {
    // No build during boot/launch, and no implicit second simulator clone.
    if booted.isEmpty { _ = try run(["simctl", "boot", identifier]) }
    _ = try run(["simctl", "bootstatus", identifier, "-b"])
    if let app = environment["IOS_SIMULATOR_APP_PATH"] {
        _ = try run(["simctl", "install", identifier, app])
    }
    if let run = environment["IOS_SIMULATOR_XCTESTRUN_PATH"] {
        arguments = ["xcodebuild", "-quiet", "-xctestrun", run, "-jobs", "1",
                     "-parallel-testing-enabled", "NO", "-resultBundlePath",
                     report.appendingPathComponent("tests.xcresult").path] + filters
    }
    arguments += ["-destination", "platform=iOS Simulator,id=\(identifier)",
                  "-maximum-concurrent-test-simulator-destinations", "1", "test-without-building"]
}
_ = try run(arguments)
