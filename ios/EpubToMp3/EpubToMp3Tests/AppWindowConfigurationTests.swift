import XCTest
@testable import EpubToMp3

final class AppWindowConfigurationTests: XCTestCase {
    #if os(macOS)
    func testMacOSDefaultWindowSizeLeavesRoomForSplitView() {
        let minimum = EpubToMp3WindowConfiguration.macOSMinimumSize
        let size = EpubToMp3WindowConfiguration.macOSDefaultSize

        XCTAssertGreaterThanOrEqual(minimum.width, 1000)
        XCTAssertGreaterThanOrEqual(minimum.height, 700)
        XCTAssertGreaterThanOrEqual(size.width, 1000)
        XCTAssertGreaterThanOrEqual(size.height, 700)
    }

    func testMacOSWindowBootstrapRetriesAfterSwiftUISceneCreation() {
        let delays = EpubToMp3WindowConfiguration.macOSWindowConfigurationAttemptDelays
        XCTAssertGreaterThanOrEqual(delays.count, 6)
        XCTAssertGreaterThanOrEqual(delays.last ?? 0, 2)
    }
    #endif
}