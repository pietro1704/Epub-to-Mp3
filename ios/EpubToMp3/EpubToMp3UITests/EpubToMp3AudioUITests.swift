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
}
