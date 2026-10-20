import Foundation
import Darwin
import XCTest
@testable import DeviceWorkflow

final class AppCleanupTests: XCTestCase {
    private var root: URL!
    private var originalPath: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-cleanup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tool = root.appendingPathComponent("xcrun")
        try Data("#!/bin/sh\nprintf 'fake device tool completed'\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        // posix_spawnp resolves in the parent's PATH, before applying child envp.
        // This XCTest suite runs serially; restore PATH before removing fixtures.
        originalPath = ProcessInfo.processInfo.environment["PATH"]
        guard setenv("PATH", root.path, 1) == 0 else { throw WorkflowError("Cannot install fake-tool PATH") }
    }

    override func tearDownWithError() throws {
        if let originalPath { setenv("PATH", originalPath, 1) } else { unsetenv("PATH") }
        try FileManager.default.removeItem(at: root)
    }

    private func command(_ phase: String = "appCleanupInspection") -> Command {
        Command(arguments: ["xcrun", "devicectl", "device", "info", "processes", "--device", "literal-device",
                            "--timeout", "30", "--json-output", root.appendingPathComponent("processes.json").path],
                environment: ["PATH": root.path], directory: root,
                log: root.appendingPathComponent("tool.log"), timeout: 1, phase: phase)
    }

    func testCancellationAllowsOnlyBoundedCleanupAndReapsItsChild() throws {
        var observations: [Int32?] = []
        let result = try HostProcess.run(command(), interrupted: { true }) { observations.append($0) }
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.output, "fake device tool completed")
        XCTAssertEqual(observations.count, 2)
        XCTAssertNotNil(observations[0])
        XCTAssertNil(observations[1])
    }

    func testCancellationRefusesNormalWorkAndSpoofedCleanupWithoutSpawning() throws {
        var candidates = [command("testWall")]
        var launch = command()
        launch.arguments = ["xcrun", "simctl", "boot", "unrelated-device"]
        candidates.append(launch)
        var extended = command()
        extended.arguments += ["--untrusted"]
        candidates.append(extended)
        var unbounded = command()
        unbounded.timeout = 61
        candidates.append(unbounded)
        for candidate in candidates {
            XCTAssertThrowsError(try HostProcess.run(candidate, interrupted: { true }) { _ in XCTFail("Must not spawn") })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tool.log").path))
    }

    func testTerminationRequiresExactProtocolAndPositiveBoundedPID() {
        var request = command("appCleanupTermination")
        request.arguments = ["xcrun", "devicectl", "device", "process", "terminate", "--device", "literal-device", "--pid", "42"]
        XCTAssertTrue(HostProcess.isAppCleanup(request))
        for pid in ["0", "-1", "2147483648", "42; anything"] {
            request.arguments[8] = pid
            XCTAssertFalse(HostProcess.isAppCleanup(request))
        }
    }

    func testCleanupRetainsTimeoutAndReapsOwnedChild() throws {
        try Data("#!/bin/sh\n/bin/sleep 10\n".utf8).write(to: root.appendingPathComponent("xcrun"))
        var request = command()
        request.timeout = 0.05
        var observations: [Int32?] = []
        XCTAssertThrowsError(try HostProcess.run(request, interrupted: { true }) { observations.append($0) }) {
            XCTAssertTrue(String(describing: $0).contains("timed out"))
        }
        XCTAssertEqual(observations.count, 2)
        XCTAssertNotNil(observations[0])
        XCTAssertNil(observations[1])
    }
}
