#if DEBUG
import CryptoKit
import Foundation
import XCTest

@MainActor
final class ReaderFootnotesAvailabilityUITests: XCTestCase {
    func testMoreMenuHidesFootnotesInThePlainChapterAndRestoresThemOnReturn() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "FootnotesAvailability", withExtension: "epub"))
        let epub = try Data(contentsOf: url)
        let digest = SHA256.hash(data: epub).prefix(16).map { String(format: "%02x", $0) }.joined()
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTestEPUBSeed", epub.base64EncodedString(), "-uiTestResetActiveReader",
            "-uiTestReaderLayout", "scrolling", "-uiTestFlickerProbe",
            "-reader.recentTool.v1", "appearance",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        defer { app.terminate() }

        let playerClose = app.buttons["fullPlayer.close"].firstMatch
        if playerClose.exists && playerClose.isHittable { playerClose.tap() }
        let library = app.tabBars.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        library.tap()
        let tile = app.descendants(matching: .any)["library.bookTile.\(digest)"].firstMatch
        if !tile.waitForExistence(timeout: 2) || !tile.isHittable {
            let search = app.searchFields["library.searchField"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("Footnotes Availability Test Fixture")
        }
        XCTAssertTrue(tile.waitForExistence(timeout: 8) && tile.isHittable)
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        let more = app.buttons["reader.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 12))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 15))

        // Explicit chapter selection also makes repeated runs independent of the fixture's saved position.
        openMore(in: app)
        selectChapter("Annotated Chapter", ordinal: 0, in: app)
        openMore(in: app)
        XCTAssertTrue(command("reader.footnotes", title: "Footnotes", in: app).exists)
        attachScreenshot("footnotes-in-annotated-chapter", app: app)

        selectChapter("Plain Chapter", ordinal: 1, in: app)
        openMore(in: app)
        XCTAssertFalse(command("reader.footnotes", title: "Footnotes", in: app).exists)
        attachScreenshot("footnotes-absent-in-plain-chapter", app: app)

        selectChapter("Annotated Chapter", ordinal: 0, in: app)
        openMore(in: app)
        let footnotes = command("reader.footnotes", title: "Footnotes", in: app)
        XCTAssertTrue(footnotes.exists && footnotes.isHittable)
        attachScreenshot("footnotes-restored-on-return", app: app)
        footnotes.tap()
        XCTAssertTrue(app.tables.staticTexts["The lantern was borrowed from the ferryman."].firstMatch
            .waitForExistence(timeout: 5))
    }

    private func command(_ identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (identifier == %@ OR label == %@)",
            Int(XCUIElement.ElementType.button.rawValue), Int(XCUIElement.ElementType.menuItem.rawValue), identifier, title
        )).firstMatch
    }

    private func openMore(in app: XCUIApplication) {
        let more = app.buttons["reader.more"].firstMatch
        XCTAssertTrue(more.exists && more.isHittable)
        more.tap()
        let search = command("reader.search", title: "Search", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 4) && search.isHittable, "The native More menu must be open")
    }

    private func selectChapter(_ title: String, ordinal: Int, in app: XCUIApplication) {
        let contents = command("reader.toc.toggle", title: "Contents", in: app)
        XCTAssertTrue(contents.exists && contents.isHittable)
        contents.tap()
        let table = app.tables["reader.toc"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let row = table.cells.matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(row.exists && row.isHittable)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(table.waitForNonExistence(timeout: 5))

        let chapter = app.staticTexts["flicker.probe.chapter"].firstMatch
        let selectedChapter = NSPredicate(format: "label == %@", "\(ordinal)/2")
        let mounted = XCTNSPredicateExpectation(predicate: selectedChapter, object: chapter)
        XCTAssertEqual(XCTWaiter.wait(for: [mounted], timeout: 5), .completed, "The selected chapter must be visible")
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }
}
#endif
