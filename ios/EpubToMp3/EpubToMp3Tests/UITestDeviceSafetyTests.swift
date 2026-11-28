import XCTest

/// UI tests that clear reading progress while using real books (no `-uiTestFixture`) must never run on a physical
/// device, where that progress belongs to the listener. Each one calls `requireSimulator()`, which skips there.
final class UITestDeviceSafetyTests: XCTestCase {
    private static let guardCall = "try requireSimulator()"
    /// The shared ways of launching a real seeded book with a progress reset.
    private static let seededLaunches = [".seededLOTR", ".paginatedNativeLOTR", "launchNativeLOTR()"]

    private var uiTestFiles: [URL] {
        get throws {
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3UITests")
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "swift" }
        }
    }

    func testEveryTestThatLaunchesASeededRealBookRefusesAPhysicalDevice() throws {
        var checked = 0
        var offenders: [String] = []
        for file in try uiTestFiles where file.lastPathComponent != "ReaderModesHarness.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for function in source.components(separatedBy: "func ").dropFirst() where function.hasPrefix("test") {
                guard Self.seededLaunches.contains(where: function.contains) else { continue }
                checked += 1
                if !function.contains(Self.guardCall) {
                    offenders.append("\(file.lastPathComponent): \(function.prefix { $0 != "(" })")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "the scan must find the seeded tests")
        XCTAssertEqual(offenders.sorted(), [], "These tests reset real reading progress on a device")
    }

    func testEveryFileThatResetsProgressWithoutTheFixtureRefusesAPhysicalDevice() throws {
        var checked = 0
        var offenders: [String] = []
        for file in try uiTestFiles where file.lastPathComponent != "ReaderModesHarness.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("\"-uiTestResetReaderPosition\""),
                  !source.contains("\"-uiTestFixture\""),
                  !source.contains("\"-uiTestIsolatedSettings\"") else { continue }
            checked += 1
            if !source.contains(Self.guardCall) { offenders.append(file.lastPathComponent) }
        }
        XCTAssertGreaterThan(checked, 0, "the scan must find the real-book tests")
        XCTAssertEqual(offenders.sorted(), [], "These tests reset real reading progress on a device")
    }
}
