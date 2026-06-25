import XCTest

/// Captures a rapid screenshot burst across a chapter boundary so the
/// "wrong interleaved page" flash can be inspected frame by frame. Drives to
/// the last page of chapter 1, then taps forward and snaps several frames in
/// quick succession during the curl + swap. Attaches them for manual review.
final class ChapterCrossFlashUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func chapter(_ app: XCUIApplication) -> (index: Int, total: Int)? {
        let label = app.staticTexts["flicker.probe.chapter"].firstMatch.label
        let parts = label.split(separator: "/").map(String.init)
        guard parts.count == 2, let i = Int(parts[0]), let t = Int(parts[1]) else { return nil }
        return (i, t)
    }
    private func indicator(_ app: XCUIApplication) -> (page: Int, total: Int)? {
        let label = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let parts = label.split(separator: " ").map(String.init)
        guard parts.count >= 3, let p = Int(parts[0]), let t = Int(parts[2]) else { return nil }
        return (p, t)
    }

    func testCaptureChapterCrossingBurst() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFlickerProbe", "-uiTestResetReaderPosition"]
        app.launch()

        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard app.staticTexts["reader.pageIndicator"].firstMatch.waitForExistence(timeout: 20),
              let startCh = chapter(app), startCh.index + 1 < startCh.total else {
            throw XCTSkip("No room to cross a chapter boundary.")
        }

        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        var guardCount = 0
        while let cur = indicator(app), cur.page < cur.total, guardCount < 80 {
            right.tap(); usleep(650_000); guardCount += 1
        }
        attach(app, "before-cross-last-page")

        // The crossing tap, then a tight burst of frames during the swap.
        right.tap()
        for i in 0..<8 {
            attach(app, String(format: "cross-frame-%02d", i))
            usleep(120_000)   // ~120 ms between frames spans the curl + swap
        }
        attach(app, "after-cross-settled")

        // Sanity: we actually advanced.
        XCTAssertEqual(chapter(app)?.index, startCh.index + 1,
                       "must have crossed into the next chapter")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
