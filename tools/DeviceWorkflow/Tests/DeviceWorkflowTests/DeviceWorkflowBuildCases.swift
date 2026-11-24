import XCTest
import Foundation
import Darwin
@testable import DeviceWorkflow

extension DeviceWorkflowTests {
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

    func testLockedDeviceWaitsThenBlocksOnlyAfterTheTimeout() throws {
        let phases = NSMutableArray()
        var notices: [String] = []
        let work = try workflow(["test"], runner: fakeRunner(phases: phases, locked: true),
                                environment: ["DEVICE_UNLOCK_WAIT_SECONDS": "20"], notice: { notices.append($0) })
        XCTAssertThrowsError(try work.execute())
        // Initial query plus one poll per 5 s until the 20 s timeout; nothing is built or written.
        XCTAssertEqual(phases as? [String], Array(repeating: "lockState", count: 5))
        XCTAssertEqual(work.report["status"] as? String, "blocked")
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].hasPrefix("WAITING_FOR_UNLOCK device="), notices[0])
        XCTAssertTrue(notices[0].contains(" since="))
    }

    /// DEVICE-WAIT-RELEASES-LEASE: a locked iPhone must not freeze every other native job on the Mac. The heavy lease is
    /// taken only once the device is unlocked, and held from then on.
    func testWaitingForUnlockDoesNotHoldTheHeavyLease() throws {
        _ = try appFixture()
        let heavy = root.appendingPathComponent("heavy.lock")
        var freeDuringWait: [Bool] = []
        let phases = NSMutableArray()
        let work = try workflow(["test"], runner: fakeRunner(phases: phases, lockedQueries: 3),
                                sleeper: { _ in freeDuringWait.append((try? FileLease(heavy)) != nil) })
        XCTAssertEqual(try work.execute()["status"] as? String, "passed")
        XCTAssertEqual(freeDuringWait, [true, true, true], "Another job must be able to take the lease while the phone is locked")
        XCTAssertTrue((phases as? [String] ?? []).contains("build"), "The run still builds and tests once unlocked")
    }

    func testTimeoutWhileLockedNeverTookTheHeavyLease() throws {
        let heavy = root.appendingPathComponent("heavy.lock")
        let work = try workflow(["test"], runner: fakeRunner(phases: NSMutableArray(), locked: true),
                                environment: ["DEVICE_UNLOCK_WAIT_SECONDS": "10"])
        XCTAssertThrowsError(try work.execute())
        XCTAssertNotNil(try? FileLease(heavy), "A blocked run leaves the lease free")
    }

    func testZeroWaitKeepsTheImmediateRefusal() throws {
        let phases = NSMutableArray()
        let work = try workflow(["test"], runner: fakeRunner(phases: phases, locked: true),
                                environment: ["DEVICE_UNLOCK_WAIT_SECONDS": "0"])
        XCTAssertThrowsError(try work.execute())
        XCTAssertEqual(phases as? [String], ["lockState"])
        XCTAssertEqual(work.report["status"] as? String, "blocked")
    }

    func testLockedDeviceContinuesWhenItUnlocksDuringTheWait() throws {
        _ = try appFixture()
        let phases = NSMutableArray()
        var notices: [String] = []
        var statusesWhenAnnounced: [String] = []
        var announcing: Workflow?
        let work = try workflow(["test"], runner: fakeRunner(phases: phases, lockedQueries: 3),
                                notice: { notices.append($0); statusesWhenAnnounced.append(announcing?.report["status"] as? String ?? "") })
        announcing = work
        let report = try work.execute()
        XCTAssertEqual(report["status"] as? String, "passed")
        XCTAssertEqual(notices.count, 1, "One WAITING_FOR_UNLOCK line, not one per poll.")
        XCTAssertEqual(statusesWhenAnnounced, ["waiting_for_unlock"], "The report says so while it waits.")
        let executed = phases as? [String] ?? []
        XCTAssertEqual(Array(executed.prefix(4)), Array(repeating: "lockState", count: 4),
                       "Three locked polls, then the unlocked one; the run goes on to details/build.")
        XCTAssertTrue(executed.contains("build"))
        XCTAssertNotNil(report["unlockedAfterWaitingSince"])
        XCTAssertGreaterThanOrEqual((work.report["timings"] as? [String: Any])?["deviceWaitSeconds"] as? Double ?? 0, 10)
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
        XCTAssertEqual(work.report["appCleanupVerified"] as? Bool, true)
        XCTAssertEqual(Array(executed.suffix(4)), ["appCleanupInspection", "appCleanupRevalidation", "appCleanupTermination", "appCleanupVerification"])
    }

    func testSharedXcodeDerivedDataSuppliesBuildTestAppAndBenchmarkHost() throws {
        let shared = root.appendingPathComponent("GUI DerivedData")
        try assertDerivedDataWorkflow(selected: shared, environment: ["APPLE_DERIVED_DATA_PATH": shared.path])
    }

    func testExplicitIOSDerivedDataTakesPriorityOverSharedXcodeCache() throws {
        let shared = root.appendingPathComponent("GUI DerivedData")
        let isolated = root.appendingPathComponent("isolated iOS DerivedData")
        // A valid competing cache must not win app or xctestrun discovery.
        _ = try appFixture(derivedData: shared)
        try assertDerivedDataWorkflow(selected: isolated, environment:
            ["APPLE_DERIVED_DATA_PATH": shared.path, "IOS_DERIVED_DATA_PATH": isolated.path])
    }

    func testTestFailureStillVerifiesAppShutdownAndPreservesPrimaryError() throws {
        _ = try appFixture()
        let phases = NSMutableArray()
        let fallback = fakeRunner(phases: phases)
        let work = try workflow(["test"], runner: { command, observe in
            if command.phase == "testWall" {
                _ = try fallback(command, observe)
                throw WorkflowError("original test failure")
            }
            return try fallback(command, observe)
        })
        XCTAssertThrowsError(try work.execute()) { XCTAssertTrue(String(describing: $0).contains("original test failure")) }
        XCTAssertEqual(work.report["appCleanupVerified"] as? Bool, true)
    }
}
