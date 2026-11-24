import XCTest

@MainActor
final class HomeWidgetGalleryUITests: XCTestCase {
    func testHomeWidgetPreviewsAreAvailableInTheSystemGallery() throws {
        // Supervised only: it needs the app already running in the foreground and drives
        // SpringBoard. Opt in with TEST_RUNNER_EPUB2MP3_WIDGET_GALLERY=1 on xcodebuild; any
        // other test run skips it instead of failing.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EPUB2MP3_WIDGET_GALLERY"] == "1",
                          "Set EPUB2MP3_WIDGET_GALLERY=1 in a supervised device run")
        continueAfterFailure = false
        let app = XCUIApplication()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // XCTest's launch reinstalls the host app and clears WidgetKit's
        // descriptors. Use the instance already launched by the supervisor.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 12),
                      "The supervisor must launch the app before opening the widget gallery")
        XCUIDevice.shared.press(.home)
        defer {
            XCUIDevice.shared.press(.home)
        }

        let icon = springboard.icons.matching(NSPredicate(format: "label CONTAINS[c] %@", "EpubToMp3")).firstMatch
        for _ in 0..<3 where !icon.isHittable { springboard.swipeLeft() }
        // Diagnostics for a supervised run: which icons SpringBoard really exposes (page, label, hittable).
        let report = springboard.icons.allElementsBoundByIndex.map { "\($0.label) hittable=\($0.isHittable)" }.joined(separator: "\n")
        print("SpringBoard icons:\n\(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = "springboard-icon-labels"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(icon.waitForExistence(timeout: 4) && icon.isHittable, "The app icon must be on the Home Screen")
        icon.press(forDuration: 1.2)

        let edit = element(in: springboard, labels: ["Edit Home Screen", "Editar Tela de Início", "Editar pantalla de inicio"])
        XCTAssertTrue(edit.waitForExistence(timeout: 4))
        edit.tap()
        let add = element(in: springboard, labels: ["Add Widget", "Add Widgets", "Adicionar Widget", "Añadir widget"])
        XCTAssertTrue(add.waitForExistence(timeout: 4), "SpringBoard must expose its widget gallery control")
        add.tap()

        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Epub")
        let results = matchingElements(in: springboard, labels: ["EpubToMp3", "EpubToMp3 Widget"])
        let result = try XCTUnwrap(waitForElement(results) {
            $0.elementType != .icon && $0.frame.minY >= search.frame.maxY
        }, "WidgetKit must list the app below the gallery search field")
        result.tap()

        let addButtons = matchingElements(in: springboard, labels: ["Add Widget", "Adicionar Widget", "Añadir widget"])
        XCTAssertNotNil(waitForElement(addButtons) {
            $0.frame.midY > springboard.frame.midY
        }, "The gallery must open the provider's widget carousel")
        let playback = element(in: springboard, labels: ["Now Playing", "Tocando Agora", "Reproduciendo Ahora"])
        let library = element(in: springboard, labels: ["Library", "Biblioteca"])
        var sawPlayback = false
        var sawLibrary = false
        for _ in 0..<6 {
            if !sawPlayback && playback.exists && playback.isHittable {
                sawPlayback = true
                attachPreview(springboard, name: "widget-gallery-now-playing")
            }
            if !sawLibrary && library.exists && library.isHittable {
                sawLibrary = true
                attachPreview(springboard, name: "widget-gallery-library")
            }
            if sawPlayback && sawLibrary { break }
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.79, dy: 0.48))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.48)))
        }
        XCTAssertTrue(sawPlayback, "The gallery must show a Now Playing preview")
        XCTAssertTrue(sawLibrary, "The gallery must show a Library preview")
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
