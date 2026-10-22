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
        XCTAssertEqual(work.report["appCleanupVerified"] as? Bool, true)
        XCTAssertTrue(executed.firstIndex(of: "nativeBuildPreflight")! < executed.firstIndex(of: "build")!)
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
