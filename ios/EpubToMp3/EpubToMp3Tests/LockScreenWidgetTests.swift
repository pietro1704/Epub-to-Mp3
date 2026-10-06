import XCTest

final class LockScreenWidgetTests: XCTestCase {
    func testLockScreenWidgetAdoptsContainerBackgroundAPI() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3Widget/LockScreenWidgets.swift")
        )
        XCTAssertTrue(
            source.contains("containerBackground(for: .widget)"),
            "Lock Screen widgets must adopt WidgetKit's container background API."
        )
    }
}
