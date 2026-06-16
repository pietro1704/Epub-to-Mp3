import XCTest

final class EpubToMp3AudioUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReaderPlayButtonStartsPlaybackOnDevice() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launch()

        let playButton = app.buttons["Reproduzir"].firstMatch
        XCTAssertTrue(
            playButton.waitForExistence(timeout: 20),
            "The reader player should expose the Play button on launch."
        )

        playButton.tap()

        let pauseButton = app.buttons["Pausar"].firstMatch
        XCTAssertTrue(
            pauseButton.waitForExistence(timeout: 10),
            "Tapping Play should switch the player into the Pause state."
        )

        let positionSlider = app.sliders.firstMatch
        XCTAssertTrue(
            positionSlider.waitForExistence(timeout: 5),
            "The playback position slider should remain visible while audio is playing."
        )
    }

    func testOpenBookCenterTapChromeAndCaptureSpacingOnDevice() throws {
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        app.launch()

        let firstBook = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")).firstMatch
        XCTAssertTrue(firstBook.waitForExistence(timeout: 20), "The library should expose at least one book tile.")
        firstBook.tap()

        let readerReady = app.buttons["Buscar no livro"].firstMatch
        XCTAssertTrue(readerReady.waitForExistence(timeout: 20), "Opening a book should show the reader chrome.")

        attachScreenshot(named: "reader-01-open-with-chrome")

        tapScreenCenter(app: app)
        sleep(1)
        attachScreenshot(named: "reader-02-after-center-tap")

        tapScreenCenter(app: app)
        sleep(1)
        attachScreenshot(named: "reader-03-after-second-center-tap")
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
