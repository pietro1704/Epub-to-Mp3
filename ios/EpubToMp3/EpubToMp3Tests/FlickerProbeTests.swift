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

    /// `log(_:)` moved its file write off the main thread (blocking I/O at
    /// ~60 Hz perturbed the reader timing the probe measures). The async write
    /// must still land the message on disk.
    func testLogWritesMessageToFileOffMain() {
        let marker = "probe-marker-\(UUID().uuidString)"
        FlickerProbe.shared.log(marker)
        // Flushes the serial I/O queue before reading.
        let contents = FlickerProbe.shared.debugLogContentsForTests()
        XCTAssertEqual(contents?.contains(marker), true,
            "log(_:) must persist the message to the debug file via the I/O queue")
    }

    /// A second rapid `log(_:)` must NOT republish the overlay-driving
    /// `lastLog` (throttled to ~5 Hz) — republishing on every call re-rendered
    /// the diagnostic overlay at ~60 Hz, another self-perturbation source.
    func testLastLogPublishIsThrottled() {
        FlickerProbe.shared.log("first-\(UUID().uuidString)")
        let afterFirst = FlickerProbe.shared.lastLog
        FlickerProbe.shared.log("second-\(UUID().uuidString)")
        let afterSecond = FlickerProbe.shared.lastLog
        XCTAssertEqual(afterFirst, afterSecond,
            "a log within the throttle window must not change lastLog")
    }
}
