import XCTest
import Foundation
import Darwin
@testable import DeviceWorkflow

extension DeviceWorkflowTests {
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
}
