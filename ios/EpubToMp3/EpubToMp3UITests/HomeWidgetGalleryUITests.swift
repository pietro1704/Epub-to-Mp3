import XCTest

@MainActor
final class HomeWidgetGalleryUITests: XCTestCase {
    /// Measured on the 16e (2026-11-24, owner confirmed): the EpubToMp3 widgets live on the Today View, the page to
    /// the left of Home Screen page 1, not behind Edit Home Screen. The case goes there, captures what SpringBoard
    /// shows and checks that the app's widgets are on it.
    func testHomeWidgetsAreOnTheTodayView() throws {
        // Supervised only: it needs the app already running in the foreground and drives SpringBoard. Opt in with
        // TEST_RUNNER_EPUB2MP3_WIDGET_GALLERY=1 on xcodebuild; any other test run skips it instead of failing.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EPUB2MP3_WIDGET_GALLERY"] == "1",
                          "Set EPUB2MP3_WIDGET_GALLERY=1 in a supervised device run")
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // XCTest's launch reinstalls the host app and clears WidgetKit's descriptors. Use the instance already
        // launched by the supervisor.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12),
                      "The supervisor must launch the app before looking at the widgets")
        XCUIDevice.shared.press(.home)
        defer { XCUIDevice.shared.press(.home) }
        sleep(2)

        // Swipe right until the Today View is showing (extra swipes on it do nothing). The Home Screen icons are
        // not on screen there; the search field is.
        for _ in 0..<4 { springboard.swipeRight(); usleep(600_000) }
        sleep(2)

        let hierarchy = XCTAttachment(string: springboard.debugDescription)
        hierarchy.name = "today-view-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let shot = XCTAttachment(screenshot: springboard.screenshot())
        shot.name = "today-view"
        shot.lifetime = .keepAlways
        add(shot)

        // Widgets of this app show its name in their accessibility label or identifier ("EpubToMp3, Now Playing...").
        let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", "EpubToMp3", "EpubToMp3")
        let widgets = springboard.descendants(matching: .any).matching(predicate)
        let labels = widgets.allElementsBoundByIndex.map { "\($0.elementType.rawValue) \($0.label) | \($0.identifier) | \($0.frame)" }
        let listing = XCTAttachment(string: labels.joined(separator: "\n"))
        listing.name = "today-view-epubtomp3-elements"
        listing.lifetime = .keepAlways
        add(listing)
        XCTAssertGreaterThan(widgets.count, 0, "The Today View must show the app's widgets")
    }

    private func element(in app: XCUIApplication, labels: [String]) -> XCUIElement {
        matchingElements(in: app, labels: labels).firstMatch
    }

    private func matchingElements(in app: XCUIApplication, labels: [String]) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN[c] %@", labels))
    }

    private func waitForElement(_ elements: XCUIElementQuery, matching matches: @escaping (XCUIElement) -> Bool) -> XCUIElement? {
        var result: XCUIElement?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            result = elements.allElementsBoundByIndex.first { $0.isHittable && matches($0) }
            return result != nil
        }, object: nil)
        _ = XCTWaiter.wait(for: [expectation], timeout: 6)
        return result
    }

    private func attachPreview(_ springboard: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: springboard.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
