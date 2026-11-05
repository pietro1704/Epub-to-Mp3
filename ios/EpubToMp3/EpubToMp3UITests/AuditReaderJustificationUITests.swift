import XCTest

@MainActor
final class AuditReaderJustificationUITests: XCTestCase {
    func testSeededJustifiedReaderPreservesGlyphsAndLocationThroughChromeAndPageTurns() throws {
        continueAfterFailure = false
        let harness = ReaderModesHarness()
        let app = harness.launch(.init(source: .seededLOTR, layout: "paginated", smallFont: true,
            chromeToggleEnabled: true, paginationProbeEnabled: true,
            additionalArguments: ["-readerOverrideTextAlignment", "YES", "-readerTextAlignment", "justified"]))
        defer { app.terminate() }
        try harness.openBook(titleContaining: "lord")
        XCTAssertTrue(wait { (harness.paginationMetrics?.total ?? 0) > 1 })
        harness.assertNoClippedLines(scenario: "small justified native LOTR")
        harness.turnPage(forward: true)
        let before = try XCTUnwrap(harness.paginationMetrics)
        for _ in 0..<2 {
            harness.toggleChromeAndSettle(visible: false)
            harness.assertNoClippedLines(scenario: "hidden justified native LOTR")
            harness.toggleChromeAndSettle(visible: true)
            XCTAssertEqual(harness.paginationMetrics?.values["offset"], before.values["offset"])
            XCTAssertEqual(harness.paginationMetrics?.values["first"], before.values["first"])
            harness.assertNoClippedLines(scenario: "restored justified native LOTR")
        }
        harness.turnPage(forward: false)
        harness.assertNoClippedLines(scenario: "backward justified page")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "se1-ios15-small-justified-lotr"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let probe = XCTAttachment(string: String(describing: harness.paginationMetrics?.values ?? [:]))
        probe.name = "se1-ios15-justified-pagination"
        probe.lifetime = .keepAlways
        add(probe)
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 30) == .completed
    }
}
