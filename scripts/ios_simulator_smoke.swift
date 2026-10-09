import Foundation
import Darwin

// Explicit low-resource opt-in; never boot while compiling on this host.
let environment = ProcessInfo.processInfo.environment
guard environment["IOS_ALLOW_LOW_RESOURCE_SIMULATOR"] == "1",
      let identifier = environment["IOS_SIMULATOR_UDID"], UUID(uuidString: identifier) != nil,
      let mode = CommandLine.arguments.dropFirst().first, ["build", "test"].contains(mode)
else { fputs("Specify Simulator UUID and explicit low-resource opt-in.\n", stderr); exit(2) }
let lease = open("/tmp/epub2mp3.heavy-job.lock", O_CREAT | O_RDWR, 0o600)
guard lease >= 0 && flock(lease, LOCK_EX | LOCK_NB) == 0 else { exit(75) }
defer { close(lease) }
var load = [Double](repeating: 0, count: 3)
guard getloadavg(&load, 3) == 3, load[0] < 6 else {
    fputs("Host load is too high; no Simulator work started.\n", stderr); exit(75)
}
func run(_ arguments: [String], capture: Bool = false) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    let pipe = Pipe()
    if capture { process.standardOutput = pipe }
    try process.run()
    let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    if mode == "test" && !capture {
        while process.isRunning {
            Thread.sleep(forTimeInterval: 1)
            var currentLoad = [Double](repeating: 0, count: 3)
            if getloadavg(&currentLoad, 3) == 3 && currentLoad[0] > 12 {
                fputs("Unsafe host load \(currentLoad[0]) during Simulator test; stopping exact device.\n", stderr)
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
let filters = ["-only-testing:EpubToMp3Tests/BundledConverterFFISmokeTests",
               "-only-testing:EpubToMp3UITests/LibrarySearchUITests/testSearchBarFiltersAndClears"]
var arguments = ["xcodebuild", "-quiet", "-project", root + "/ios/EpubToMp3/EpubToMp3.xcodeproj",
                 "-scheme", "EpubToMp3", "-configuration", "Debug", "-jobs", "1",
                 "-parallel-testing-enabled", "NO", "-derivedDataPath", root + "/ios/EpubToMp3/.build",
                 "-resultBundlePath", report.appendingPathComponent("tests.xcresult").path] + filters
if mode == "build" {
    arguments += ["-destination", "generic/platform=iOS Simulator", "build-for-testing"]
} else {
    // No build during boot/launch, and no implicit second simulator clone.
    if booted.isEmpty { _ = try run(["simctl", "boot", identifier]) }
    _ = try run(["simctl", "bootstatus", identifier, "-b"])
    arguments += ["-destination", "platform=iOS Simulator,id=\(identifier)",
                  "-maximum-concurrent-test-simulator-destinations", "1", "test-without-building"]
}
_ = try run(arguments)
