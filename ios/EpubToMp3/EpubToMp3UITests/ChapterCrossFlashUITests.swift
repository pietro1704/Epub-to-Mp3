import XCTest

/// Lightweight check that a SWIPE across a chapter boundary does not flash a
/// wrong page during the curl. We only read the single `reader.pageIndicator`
/// element (a fast query) — never enumerate the whole accessibility tree,
/// which hangs on device. Across the swipe, the visible page number must go
/// straight from the old chapter's LAST page to the new chapter's page 1,
/// without exposing an intermediate page in between.
@MainActor
final class ChapterCrossFlashUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func indicator(_ app: XCUIApplication) -> (page: Int, total: Int)? {
        let label = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let parts = label.split(separator: " ").map(String.init)
        guard parts.count >= 3, let p = Int(parts[0]), let t = Int(parts[2]) else { return nil }
        return (p, t)
    }

    func testSwipeCrossingDoesNotFlashIntermediatePage() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestResetReaderPosition", "-uiTestReaderLayout", "paginated"]
        app.launch()

        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard indicator(app) != nil else { throw XCTSkip("No page indicator.") }

        // Page to the last page of the current chapter by tapping the right.
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        var guardCount = 0
        while let cur = indicator(app), cur.page < cur.total, guardCount < 60 {
            right.tap(); usleep(650_000); guardCount += 1
        }
        guard let last = indicator(app), last.page == last.total else {
            throw XCTSkip("Could not reach the last page.")
        }
        let oldLastPage = last.page
        let oldTotal = last.total

        // Swipe forward off the last page → crosses to next chapter. Sample the
        // indicator in a tight burst during the curl.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)

        var sequence: [(Int, Int)] = []
        for _ in 0..<14 {
            if let ind = indicator(app) { sequence.append((ind.page, ind.total)) }
            usleep(50_000)
        }

        // The reader must end on page 1 of a (possibly different-length) new
        // chapter.
        guard let settled = indicator(app) else { return XCTFail("indicator gone") }
        XCTAssertEqual(settled.page, 1,
                       "after swipe-crossing the reader must settle on page 1; sequence=\(sequence)")

        // No frame may show an intermediate page of the OLD chapter (a page
        // strictly between 1 and its last, with the OLD total) — that is the
        // curl flashing a wrong page mid-swap.
        let badOldFrames = sequence.filter { $0.1 == oldTotal && $0.0 > 1 && $0.0 < oldLastPage }
        XCTAssertTrue(badOldFrames.isEmpty,
                      "no intermediate OLD-chapter page may flash during the swipe; saw \(badOldFrames) in \(sequence)")
    }
}
