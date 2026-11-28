import XCTest
import Foundation
@testable import DeviceWorkflow

extension DeviceWorkflowTests {
    /// What xcodebuild prints when the app cannot be brought to the front, for example while another app stays there.
    private var launchFailure: String {
        "<unknown>:0: error: -[EpubToMp3UITests.SampleUITests testSample] : Failed to get launch progress for <XCUIApplicationImpl>: "
            + "The process identifier of the launched application could not be determined. It may have already terminated."
    }

    private func runner(_ phases: NSMutableArray, failedLaunches: Int, output: String,
                        bundles: NSMutableArray = NSMutableArray(),
                        existedBeforeLaunch: NSMutableArray = NSMutableArray()) -> CommandRunner {
        let base = fakeRunner(phases: phases)
        var remaining = failedLaunches
        return { command, observe in
            if command.phase == "testWall" {
                let path = command.arguments[command.arguments.firstIndex(of: "-resultBundlePath")! + 1]
                existedBeforeLaunch.add(FileManager.default.fileExists(atPath: path))
            }
            let result = try base(command, observe)
            guard command.phase == "testWall" else { return result }
            bundles.add(command.arguments[command.arguments.firstIndex(of: "-resultBundlePath")! + 1])
            guard remaining > 0 else { return result }
            remaining -= 1
            return CommandResult(code: 65, output: output)
        }
    }

    func testLaunchThatCannotReachTheForegroundWaitsAndRunsAgain() throws {
        _ = try appFixture()
        let heavy = root.appendingPathComponent("heavy.lock")
        let phases = NSMutableArray()
        let bundles = NSMutableArray()
        let existedBeforeLaunch = NSMutableArray()
        var naps: [TimeInterval] = []
        var freeDuringWait: [Bool] = []
        var notices: [String] = []
        let work = try workflow(["test"], runner: runner(phases, failedLaunches: 2, output: launchFailure, bundles: bundles,
                                                                 existedBeforeLaunch: existedBeforeLaunch),
                                sleeper: { naps.append($0); freeDuringWait.append((try? FileLease(heavy)) != nil) },
                                notice: { notices.append($0) })
        XCTAssertEqual(try work.execute()["status"] as? String, "passed")
        XCTAssertEqual((phases as? [String] ?? []).filter { $0 == "testWall" }.count, 3)
        XCTAssertEqual((phases as? [String] ?? []).filter { $0 == "build" }.count, 1, "Waiting never rebuilds")
        XCTAssertEqual(naps, [15, 15])
        XCTAssertEqual(freeDuringWait, [true, true], "Waiting for the foreground holds no heavy lease")
        XCTAssertEqual(notices.filter { $0.hasPrefix("WAITING_FOR_FOREGROUND device=") }.count, 1)
        // Every bundle of a launch that never reached the app may record another app, so it is deleted before the
        // next launch; only the bundle of the run that reached the app is left.
        XCTAssertEqual(existedBeforeLaunch as? [Bool], [false, false, false])
        XCTAssertTrue(FileManager.default.fileExists(atPath: (bundles as? [String])?.last ?? ""))
    }

    /// A long wait must survive a device query that times out; only the deadline ends it.
    func testAFailedLockQueryDuringTheWaitKeepsWaiting() throws {
        _ = try appFixture()
        let base = fakeRunner(phases: NSMutableArray(), lockedQueries: 2)
        var queries = 0
        let work = try workflow(["test"], runner: { command, observe in
            if command.phase == "lockState" {
                queries += 1
                if queries == 2 { return CommandResult(code: 2, output: "ERROR: Command timeout of 30.0 seconds exceeded.") }
            }
            return try base(command, observe)
        })
        XCTAssertEqual(try work.execute()["status"] as? String, "passed")
        XCTAssertGreaterThanOrEqual(queries, 3)
    }

    /// The phone can lock between the readiness check and the launch: xcodebuild then waits for the unlock until
    /// the workflow times it out. Nothing ran, so the run goes back to waiting.
    func testLockBetweenTheCheckAndTheLaunchWaitsAndRunsAgain() throws {
        _ = try appFixture()
        let base = fakeRunner(phases: NSMutableArray())
        var launches = 0
        let work = try workflow(["test"], runner: { command, observe in
            let result = try base(command, observe)
            guard command.phase == "testWall" else { return result }
            launches += 1
            guard launches == 1 else { return result }
            try Data(("Run Destination Preflight: The destination is not ready.\n"
                + "NSLocalizedDescription=Unlock iPhone to Continue\n").utf8).write(to: command.log)
            throw WorkflowError("testWall timed out; inspect testWall.log.")
        })
        XCTAssertEqual(try work.execute()["status"] as? String, "passed")
        XCTAssertEqual(launches, 2)
    }

    func testATimeoutOfATestThatStartedIsNotRetried() throws {
        _ = try appFixture()
        let base = fakeRunner(phases: NSMutableArray())
        var launches = 0
        let work = try workflow(["test"], runner: { command, observe in
            let result = try base(command, observe)
            guard command.phase == "testWall" else { return result }
            launches += 1
            try Data(("NSLocalizedDescription=Unlock iPhone to Continue\n"
                + "Test Case '-[EpubToMp3UITests.SampleUITests testSample]' started.\n").utf8).write(to: command.log)
            throw WorkflowError("testWall timed out; inspect testWall.log.")
        })
        XCTAssertThrowsError(try work.execute())
        XCTAssertEqual(launches, 1)
    }

    func testForegroundWaitIsBoundedAndEndsBlocked() throws {
        _ = try appFixture()
        let phases = NSMutableArray()
        let work = try workflow(["test"], runner: runner(phases, failedLaunches: 99, output: launchFailure),
                                environment: ["DEVICE_UNLOCK_WAIT_SECONDS": "30"])
        XCTAssertThrowsError(try work.execute())
        XCTAssertEqual((phases as? [String] ?? []).filter { $0 == "testWall" }.count, 3)
        XCTAssertEqual(work.report["status"] as? String, "blocked")
    }

    func testAnyOtherTestFailureIsNotRetried() throws {
        _ = try appFixture()
        let assertion = "Fixture.swift:1: error: -[EpubToMp3UITests.SampleUITests testOther] : XCTAssertTrue failed"
        for output in [assertion, launchFailure + "\n" + assertion,
                       launchFailure + "\nTest Case '-[EpubToMp3UITests.SampleUITests testFirst]' passed (1.0 seconds)."] {
            let phases = NSMutableArray()
            let work = Workflow(root: root, options: try options(["test"]), runID: UUID().uuidString,
                                runner: runner(phases, failedLaunches: 99, output: output),
                                identity: { _ in "Wed Oct 7 12:00:00 2026" }, resourceCheck: {},
                                heavyLock: root.appendingPathComponent("heavy.lock"),
                                environment: ["IOS_TESTS": "EpubToMp3Tests/ReaderViewportTransitionTests"],
                                sleeper: { _ in XCTFail("A real failure must not wait") }, notice: { _ in })
            XCTAssertThrowsError(try work.execute())
            XCTAssertEqual((phases as? [String] ?? []).filter { $0 == "testWall" }.count, 1, output)
        }
    }
}
