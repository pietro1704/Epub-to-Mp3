import XCTest
@testable import EpubToMp3

@MainActor
final class FlickerProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FlickerProbe.shared.arm()
        FlickerProbe.shared.reset()
    }

    func testRecordsWhenArmed() {
        FlickerProbe.shared.record(.staleSlicePushed)
        FlickerProbe.shared.record(.staleSlicePushed)
        FlickerProbe.shared.record(.spuriousRenavigation)
        XCTAssertEqual(FlickerProbe.shared.count(.staleSlicePushed), 2)
        XCTAssertEqual(FlickerProbe.shared.count(.spuriousRenavigation), 1)
        XCTAssertEqual(FlickerProbe.shared.count(.emptyPagesShown), 0)
        XCTAssertEqual(FlickerProbe.shared.total, 3)
    }

    func testResetZeroesAllCounters() {
        FlickerProbe.shared.record(.emptyPagesShown)
        FlickerProbe.shared.reset()
        XCTAssertEqual(FlickerProbe.shared.total, 0)
    }

    func testSummaryFormat() {
        FlickerProbe.shared.record(.emptyPagesShown)
        // Stable, parseable "key=value" tokens the UI test splits on.
        let summary = FlickerProbe.shared.summary
        XCTAssertTrue(summary.contains("stale=0"), summary)
        XCTAssertTrue(summary.contains("spurious=0"), summary)
        XCTAssertTrue(summary.contains("empty=1"), summary)
    }
}
