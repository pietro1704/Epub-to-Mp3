import XCTest

final class ConversionSettingsAccessibilityTests: XCTestCase {
    func testIOS15SafeAreaAndAccessibilityContractsRemainInPlace() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("EpubToMp3/Features")
        let jobs = try String(contentsOf: sourceRoot.appendingPathComponent("Conversion/Views/JobsListScreenController.swift"))
        let settings = try String(contentsOf: sourceRoot.appendingPathComponent("Settings/Views/SettingsScreenController.swift"))
        let readerSettings = try String(contentsOf: sourceRoot.appendingPathComponent("Reader/Views/ReaderSettingsScreenController.swift"))

        XCTAssertTrue(jobs.contains("view.safeAreaLayoutGuide.bottomAnchor"))
        XCTAssertTrue(jobs.contains("jobs.refreshHint"))
        XCTAssertTrue(settings.contains("settings.openOptionHint"))
        XCTAssertTrue(readerSettings.contains("UIAccessibility.isReduceMotionEnabled"))
        XCTAssertFalse(jobs.contains("IOSRootContainer"))
    }
}
