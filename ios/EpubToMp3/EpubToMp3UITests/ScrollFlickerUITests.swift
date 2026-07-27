import XCTest

/// Scroll-mode flicker regression. Arms `FlickerProbe` and drives the
/// continuous full-book scroll up and down; a `BookChapterCell` re-parsing a
/// chapter it already rendered (same chapter id, settings unchanged) repaints
/// its text — the scroll-mode flicker. The probe counts those re-renders as
/// `stale`; after a scroll burst the count must be 0.
@MainActor
final class ScrollFlickerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func probeTotal(_ app: XCUIApplication) -> Int {
        let s = app.staticTexts["flicker.probe.summary"].firstMatch.label
        return s.split(separator: " ").compactMap { tok -> Int? in
            guard let eq = tok.firstIndex(of: "=") else { return nil }
            return Int(tok[tok.index(after: eq)...])
        }.reduce(0, +)
    }

    private func resetProbe(_ app: XCUIApplication) {
        usleep(1_500_000)
        let r = app.buttons["flicker.probe.reset"].firstMatch
        if r.waitForExistence(timeout: 5) { r.tap() }
        usleep(300_000)
    }

    func testScrollUpDownDoesNotReRenderChapters() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        app.launchArguments += [
            "-uiTestResetReaderPosition",
            "-uiTestFlickerProbe",
            "-uiTestReaderLayout", "scrolling",
        ]
        app.launch()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        // Reader chrome present == inside the book.
        guard app.buttons["reader.search"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open.")
        }
        resetProbe(app)

        // Scroll down a few screens, then back up — revisiting cells that were
        // already rendered. None should re-parse.
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        for _ in 0..<5 { lower.press(forDuration: 0.05, thenDragTo: upper); usleep(500_000) }
        for _ in 0..<5 { upper.press(forDuration: 0.05, thenDragTo: lower); usleep(500_000) }

        let total = probeTotal(app)
        XCTAssertEqual(total, 0,
                       "scrolling must not re-render already-rendered chapters (flicker); probe total=\(total)")
    }

    /// Visual capture: fast-scroll while snapping frames, to confirm no white
    /// band flashes behind a not-yet-rendered cell. Screenshots are attached
    /// for review; we don't enumerate the a11y tree (which hangs on device).
    func testFastScrollCaptureForWhiteBand() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        app.launchArguments += [
            "-uiTestResetReaderPosition",
            "-uiTestReaderLayout", "scrolling",
        ]
        app.launch()
        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard app.buttons["reader.search"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open.")
        }
        sleep(1)

        // High-velocity flings give real momentum, so the LazyVStack
        // materialises new cells mid-deceleration — exactly when a not-yet-
        // rendered cell would expose a white band.
        let window = app.windows.firstMatch
        for f in 0..<4 {
            window.swipeUp(velocity: .fast)
            for i in 0..<5 {
                let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                a.name = "scroll-\(f)-\(i < 10 ? "0" : "")\(i)"
                a.lifetime = .keepAlways
                add(a)
                usleep(50_000)
            }
        }
    }
}
