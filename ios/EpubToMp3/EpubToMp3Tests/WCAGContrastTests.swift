import XCTest
@testable import EpubToMp3

final class WCAGContrastTests: XCTestCase {
    func testRatiosMatchTheWCAGReferenceValues() {
        XCTAssertEqual(WCAGContrast.ratio((0, 0, 0), (1, 1, 1)), 21, accuracy: 0.001)
        XCTAssertEqual(WCAGContrast.ratio((1, 1, 1), (1, 1, 1)), 1, accuracy: 0.001)
        XCTAssertEqual(WCAGContrast.ratio((0.467, 0.467, 0.467), (1, 1, 1)), 4.48, accuracy: 0.03, "#777 on white")
    }

    func testAdjustedLeavesPassingColoursAndFixesFailingOnesKeepingTheHue() {
        let blue: WCAGContrast.RGB = (0, 0.3, 1)
        XCTAssertTrue(WCAGContrast.adjusted(blue, against: (1, 1, 1), minimum: 3) == blue)
        let parchment: WCAGContrast.RGB = (0.90, 0.85, 0.72)
        let darker = WCAGContrast.adjusted(blue, against: parchment, minimum: 4.5)
        XCTAssertGreaterThanOrEqual(WCAGContrast.ratio(darker, parchment), 4.5)
        XCTAssertGreaterThan(darker.b, darker.r, "Still blue")
        let night: WCAGContrast.RGB = (0.05, 0.05, 0.1)
        let lighter = WCAGContrast.adjusted((0.1, 0.2, 0.6), against: night, minimum: 4.5)
        XCTAssertGreaterThanOrEqual(WCAGContrast.ratio(lighter, night), 4.5, "Dark backgrounds lighten the link instead")
    }
}
