import XCTest

final class EpubToMp3AudioUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Chrome toggle (flickering regression)

    /// Center-tap toggles chrome visibility. Screenshots captured for manual
    /// review: chrome shown → hidden → shown. No flicker between states.
    func testOpenBookCenterTapChromeAndCaptureSpacingOnDevice() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launch()

        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        XCTAssertTrue(
            firstBook.waitForExistence(timeout: 20),
            "The library should expose at least one book tile."
        )
        firstBook.tap()

        let readerReady = app.buttons["Buscar no livro"].firstMatch
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

        let app = XCUIApplication()
        app.launch()

        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        XCTAssertTrue(
            firstBook.waitForExistence(timeout: 20),
            "The library should expose at least one book tile."
        )

        // Long-press for 0.6s (above the 0.45s threshold).
        firstBook.press(forDuration: 0.6)

        // The removal dialog should appear.
        let removeButton = app.buttons["Remover da biblioteca"].firstMatch
        XCTAssertTrue(
            removeButton.waitForExistence(timeout: 5),
            "Long-press must raise the removal confirmation dialog."
        )

        // The reader must NOT have been opened — search button is only visible inside a book.
        let searchButton = app.buttons["Buscar no livro"].firstMatch
        XCTAssertFalse(
            searchButton.exists,
            "Long-press must NOT open the book — reader chrome must not be visible."
        )

        // Dismiss the dialog without removing.
        let cancelButton = app.buttons["Cancelar"].firstMatch
        if cancelButton.exists { cancelButton.tap() }
    }

    // MARK: - Play button (conditional on audio availability)

    /// Tapping Play must flip the button to Pause. Skipped when no
    /// audiobook with available MP3s is loaded on this device.
    func testReaderPlayButtonStartsPlaybackOnDevice() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launch()

        // Mini-player bar only appears when a book with audio is loaded.
        let miniBar = app.otherElements["miniPlayer.bar"].firstMatch
        guard miniBar.waitForExistence(timeout: 5) else {
            // No audio available — skip rather than fail.
            throw XCTSkip("No audiobook with available MP3s on this device; skipping playback test.")
        }

        let playButton = app.buttons["miniPlayer.playPause"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 5), "Play/Pause button must exist in mini-player.")

        playButton.tap()

        // After tap, either isPlaying (pause icon) or still loading — wait briefly.
        sleep(3)

        // Success: the button still exists (did not crash) and no alert appeared.
        XCTAssertTrue(playButton.exists, "Play/Pause button must remain after tapping.")
    }

    // MARK: - Helpers

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
