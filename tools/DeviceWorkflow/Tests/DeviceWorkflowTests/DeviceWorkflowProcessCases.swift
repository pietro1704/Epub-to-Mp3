import XCTest
import Foundation
import Darwin
@testable import DeviceWorkflow

extension DeviceWorkflowTests {
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
