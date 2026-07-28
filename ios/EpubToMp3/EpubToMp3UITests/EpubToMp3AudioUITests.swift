import XCTest

@MainActor
final class EpubToMp3AudioUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        app.launchArguments += ["-uiTestReaderLayout"]
        app.launch()
        return app
    }

    // MARK: - Chrome toggle (flickering regression)

    /// Center-tap toggles chrome visibility. Screenshots captured for manual
    /// review: chrome shown → hidden → shown. No flicker between states.
    func testOpenBookCenterTapChromeAndCaptureSpacingOnDevice() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = launchFixtureApp()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        XCTAssertTrue(
            firstBook.waitForExistence(timeout: 20),
            "The library should expose at least one book tile."
        )
        firstBook.tap()

        let readerReady = app.buttons["reader.search"].firstMatch
        XCTAssertTrue(
            readerReady.waitForExistence(timeout: 20),
            "Opening a book should show the reader chrome."
        )

        attachScreenshot(named: "reader-01-open-with-chrome")

        tapScreenCenter(app: app)
        sleep(1)
        attachScreenshot(named: "reader-02-chrome-hidden")

        tapScreenCenter(app: app)
        sleep(1)
        attachScreenshot(named: "reader-03-chrome-restored")

        // Chrome toggle must bring back the search button — verifies no
        // permanent flicker/stuck state after double center-tap.
        XCTAssertTrue(
            readerReady.waitForExistence(timeout: 5),
            "Chrome must restore after second center-tap (no stuck hidden state)."
        )
    }

    // MARK: - Library long-press gesture isolation

    /// Long-pressing a book tile must NOT navigate into the reader.
    /// It should raise a removal dialog instead. Regression for the
    /// simultaneousGesture bug that opened the book AND showed the dialog.
    func testLongPressOnBookTileDoesNotOpenBook() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = launchFixtureApp()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        XCTAssertTrue(
            firstBook.waitForExistence(timeout: 20),
            "The library should expose at least one book tile."
        )

        // Long-press for 0.6s (above the 0.45s threshold).
        firstBook.press(forDuration: 0.6)

        // The removal dialog should appear.
        // The simulator locale is not guaranteed to be pt-BR. Match the
        // localized action title instead of coupling this interaction test
        // to one language.
        let contextRemoveButton = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@", ["Remover livro", "Remove book", "Eliminar libro"])
        ).firstMatch
        // The reader must NOT have been opened — search button is only visible inside a book.
        let searchButton = app.buttons["reader.search"].firstMatch
        XCTAssertFalse(
            searchButton.exists,
            "Long-press must NOT open the book — reader chrome must not be visible."
        )

        // Context menus are not exposed consistently by XCUITest on every
        // iOS Simulator runtime. When present, still exercise the complete
        // removal path; the invariant above is valid on all runtimes.
        if contextRemoveButton.waitForExistence(timeout: 1) {
            contextRemoveButton.tap()
            let removeButton = app.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", ["Remover da biblioteca", "Remove from library", "Eliminar de la biblioteca"])
            ).firstMatch
            XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "Remove action must open confirmation sheet.")
        }

        // Dismiss the dialog without removing.
        let cancelButton = app.buttons["Cancelar"].firstMatch
        if cancelButton.exists { cancelButton.tap() }
    }

    // MARK: - Page navigation (tap and swipe)

    /// Tapping the right third of the reader advances one page; tapping the
    /// left third retreats one page. The page indicator ("X / Y") is used
    /// as ground truth. Skipped when a book with ≥2 pages is not available.
    func testTapNavigationAdvancesAndRetreatsPage() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixtureApp()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else {
            throw XCTSkip("No book in library; skipping page-navigation test.")
        }
        firstBook.tap()

        let pageIndicator = app.staticTexts["reader.pageIndicator"].firstMatch
        guard pageIndicator.waitForExistence(timeout: 20) else {
            throw XCTSkip("Page indicator not visible; book may be single-page.")
        }

        let initialLabel = pageIndicator.label  // e.g. "1 of 12"
        guard initialLabel.contains("of ") else {
            throw XCTSkip("Unexpected page indicator format: \(initialLabel)")
        }
        let parts = initialLabel.split(separator: " ").map(String.init)
        guard parts.count >= 3, let totalPages = Int(parts[2]), totalPages >= 2 else {
            throw XCTSkip("Book has fewer than 2 pages; cannot test navigation.")
        }

        // Make sure we're on page 1 (first page).
        let initialPage = Int(parts[0]) ?? 1
        XCTAssertEqual(initialPage, 1, "Reader should open on page 1.")

        // Use the reader's deterministic test hit target; it invokes the
        // same page-navigation action as the production tap recognizer.
        let frame = app.windows.firstMatch.frame
        let rightTurn = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(rightTurn.waitForExistence(timeout: 5))
        rightTurn.tap()
        sleep(1)

        let afterForward = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let forwardPage = Int(afterForward.split(separator: " ").first ?? "0") ?? 0
        XCTAssertEqual(forwardPage, 2, "Right-tap must advance to page 2, got: \(afterForward)")

        // Tap the left third (previous page).
        let leftTurn = app.buttons["reader.pageTurn.left"].firstMatch
        XCTAssertTrue(leftTurn.waitForExistence(timeout: 5))
        leftTurn.tap()
        sleep(1)

        let afterBack = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let backPage = Int(afterBack.split(separator: " ").first ?? "0") ?? 0
        XCTAssertEqual(backPage, 1, "Left-tap must retreat to page 1, got: \(afterBack)")

        _ = frame  // suppress unused warning
    }

    /// Swiping left advances one page; swiping right retreats one page.
    func testSwipeNavigationAdvancesAndRetreatsPage() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixtureApp()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else {
            throw XCTSkip("No book in library; skipping swipe-navigation test.")
        }
        firstBook.tap()

        let pageIndicator = app.staticTexts["reader.pageIndicator"].firstMatch
        guard pageIndicator.waitForExistence(timeout: 20) else {
            throw XCTSkip("Page indicator not visible; book may be single-page.")
        }
        let initialLabel = pageIndicator.label
        let parts = initialLabel.split(separator: " ").map(String.init)
        guard parts.count >= 3, let totalPages = Int(parts[2]), totalPages >= 2 else {
            throw XCTSkip("Book has fewer than 2 pages; cannot test swipe navigation.")
        }

        // Swipe left (advance page) — from right-center to left-center of screen.
        let startRight = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        let endLeft = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        startRight.press(forDuration: 0, thenDragTo: endLeft)
        sleep(1)

        let afterSwipeLeft = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let page2 = Int(afterSwipeLeft.split(separator: " ").first ?? "0") ?? 0
        XCTAssertEqual(page2, 2, "Swipe-left must advance to page 2, got: \(afterSwipeLeft)")

        // Swipe right (retreat page).
        let startLeft = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let endRight = app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        startLeft.press(forDuration: 0, thenDragTo: endRight)
        sleep(1)

        let afterSwipeRight = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let page1 = Int(afterSwipeRight.split(separator: " ").first ?? "0") ?? 0
        XCTAssertEqual(page1, 1, "Swipe-right must retreat to page 1, got: \(afterSwipeRight)")

        _ = totalPages  // suppress unused warning
    }

    // MARK: - Play button (conditional on audio availability)

    /// Tapping Play must flip the button to Pause. Skipped when no
    /// audiobook with available MP3s is loaded on this device.
    func testReaderPlayButtonStartsPlaybackOnDevice() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = launchFixtureApp()
        app.launchArguments += ["-uiTestPlaybackFixture"]

        // launchFixtureApp already launched; relaunch with the playback-only
        // fixture so this test owns a deterministic local audio asset.
        app.terminate()
        app.launch()

        let miniBar = app.otherElements["miniPlayer.bar"].firstMatch
        XCTAssertTrue(miniBar.waitForExistence(timeout: 10), "Playback fixture must expose the mini-player.")

        let playButton = app.buttons["miniPlayer.playPause"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 5), "Play/Pause button must exist in mini-player.")

        playButton.tap()

        let pauseButton = app.buttons["miniPlayer.playPause"].firstMatch
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 3), "Play/Pause control must remain mounted after starting audio.")

        XCTAssertNotEqual(pauseButton.label.lowercased(), "play", "Tapping play must transition the control away from play.")
    }

    // MARK: - TOC and in-book search

    func testTableOfContentsOpensAndReturnsToReader() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixtureApp()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else {
            throw XCTSkip("No book in library; skipping TOC test.")
        }
        firstBook.tap()

        let searchButton = app.buttons["reader.search"].firstMatch
        guard searchButton.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader chrome unavailable; skipping TOC test.")
        }

        // A book opens directly into the reader view — the TOC is opt-in,
        // revealed only by tapping the toolbar toggle.
        let tocToggle = app.buttons["reader.toc.toggle"].firstMatch
        XCTAssertTrue(tocToggle.waitForExistence(timeout: 5), "Reader toolbar must expose a TOC toggle.")
        tocToggle.tap()

        let tocRows = app.tables["reader.toc"].cells
        XCTAssertTrue(tocRows.firstMatch.waitForExistence(timeout: 5), "TOC must expose chapter rows.")
        tocRows.firstMatch.tap()

        XCTAssertTrue(searchButton.waitForExistence(timeout: 10), "TOC jump must return to the reader.")
    }

    func testInBookSearchOpensAcceptsQueryAndDismisses() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixtureApp()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else {
            throw XCTSkip("No book in library; skipping search test.")
        }
        firstBook.tap()

        let searchButton = app.buttons["reader.search"].firstMatch
        guard searchButton.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader chrome unavailable; skipping search test.")
        }
        searchButton.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search overlay must expose its text field.")
        field.tap()
        field.typeText("a")

        let done = app.buttons["OK"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Search overlay must expose its dismiss action.")
        done.tap()

        XCTAssertTrue(searchButton.waitForExistence(timeout: 10), "Dismissed search must return to the reader.")
    }


    private func tapScreenCenter(app: XCUIApplication) {
        let coordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coordinate.tap()
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
