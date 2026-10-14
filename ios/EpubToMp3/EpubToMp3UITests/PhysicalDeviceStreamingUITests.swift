import XCTest

@MainActor
final class PhysicalDeviceStreamingUITests: XCTestCase {
    func testOptInSleepTimerUsesBrazilianPortugueseText() throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Run after the dedicated real playback fixture has been converted.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let close = app.buttons["fullPlayer.close"].firstMatch
        if !close.waitForExistence(timeout: 2) {
            let open = app.buttons["miniPlayer.open"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20))
            open.tap()
        }
        let timer = app.buttons["Timer de sono"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        timer.tap()
        let option = app.buttons["45 minutos"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        capture(app, name: "se-brazilian-portuguese-sleep-timer")
        option.tap()
        timer.tap()
        app.buttons["Desligado"].firstMatch.tap()
        close.tap()
    }

    func testOptInRealEdgeStreamingControlsAndChapterDownloads() throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Enable APP_IOS_LIVE_EDGE and stage the dedicated two-chapter development EPUB.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-developmentSeedBook", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { capture(app, name: "physical-streaming-final-state") }
        let expandedClose = app.buttons["fullPlayer.close"].firstMatch
        if expandedClose.waitForExistence(timeout: 2), expandedClose.isHittable { expandedClose.tap() }

        let browse = app.buttons["mainReader.browseLibrary"].firstMatch
        if browse.waitForExistence(timeout: 3), browse.isHittable { browse.tap() }
        let closeReader = app.buttons["reader.close"].firstMatch
        if closeReader.exists, closeReader.isHittable { closeReader.tap() }
        let bookID = ProcessInfo.processInfo.environment["EPUB2MP3_GUI_BOOK_ID"] ?? ""
        let selection = bookID.isEmpty || bookID.hasPrefix("$(")
            ? NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                          "library.bookTile.", "iPhone 16e Streaming Verification")
            : NSPredicate(format: "identifier == %@", "library.bookTile.\(bookID)")
        let tile = app.descendants(matching: .any).matching(selection).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "The dedicated real EPUB must be staged; do not use canned playback.")
        tile.tap()
        let listen = app.buttons["miniPlayer.playPause"].firstMatch
        if !listen.waitForExistence(timeout: 3) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(listen.waitForExistence(timeout: 15))
        XCTAssertTrue(listen.isHittable)
        let started = ProcessInfo.processInfo.systemUptime
        listen.tap()
        let openPlayer = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 10))
        openPlayer.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), "Reader Listen must present the real player after its first audio arrives.")
        XCTAssertTrue(wait(timeout: 10) { self.seconds(elapsed.label) > 0 }, "The actual audio playback clock must advance.")
        let firstObservedPlaybackSeconds = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(firstObservedPlaybackSeconds, 15, "GUI-observed first playback should begin promptly; native chunk timing is measured separately.")
        capture(app, name: "physical-real-streaming-playing")

        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        pause.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 3))
        let pausedAt = seconds(elapsed.label)
        let stable = expectation(description: "The playback clock remains paused")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { stable.fulfill() }
        wait(for: [stable], timeout: 3)
        XCTAssertLessThanOrEqual(abs(seconds(elapsed.label) - pausedAt), 1)

        app.buttons["fullPlayer.nextChapter"].tap()
        XCTAssertTrue(app.staticTexts["Device streaming chapter two"].firstMatch.waitForExistence(timeout: 20), "Next must select the second real chapter.")
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists, "Chapter navigation must preserve pause.")
        app.buttons["fullPlayer.previousChapter"].tap()
        XCTAssertTrue(app.staticTexts["Device streaming chapter one"].firstMatch.waitForExistence(timeout: 5), "Previous must return to the first chapter.")
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists)
        app.buttons["Play"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 3))
        let resumedClock = seconds(elapsed.label)
        XCTAssertTrue(wait(timeout: 5) { self.seconds(elapsed.label) != resumedClock }, "Resume must advance the native playback clock after chapter navigation settles.")
        let settledResumeClock = seconds(elapsed.label)
        XCTAssertTrue(wait(timeout: 3) { self.seconds(elapsed.label) > settledResumeClock })
        capture(app, name: "physical-streaming-controls-verified")
        app.buttons["Pause"].firstMatch.tap()
        let beforeForward = seconds(elapsed.label)
        app.buttons["fullPlayer.skipForward"].tap()
        XCTAssertTrue(wait(timeout: 10) { self.seconds(elapsed.label) >= beforeForward + 10 },
                      "Forward skip must reach later audio while preserving pause.")
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists)
        app.buttons["fullPlayer.skipBack"].tap()
        XCTAssertTrue(wait(timeout: 10) { self.seconds(elapsed.label) <= beforeForward + 2 })
        let progress = app.otherElements["fullPlayer.progress"].firstMatch
        XCTAssertTrue(progress.exists)
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(wait(timeout: 10) { self.seconds(elapsed.label) > 10 },
                      "The chapter scrubber must reach a later position.")
        let rate = app.buttons["fullPlayer.playbackRateButton"].firstMatch
        XCTAssertTrue(rate.isHittable, "Speed must be reachable on the compact SE viewport.")
        rate.tap()
        app.buttons["1.5x"].firstMatch.tap()
        XCTAssertTrue(wait(timeout: 3) { rate.label.contains("1.5x") || (rate.value as? String)?.contains("1.5x") == true || rate.staticTexts["1.5x"].exists })
        rate.tap()
        app.buttons["1x"].firstMatch.tap()
        let sleepTimer = app.buttons["Sleep timer"].firstMatch
        XCTAssertTrue(wait(timeout: 3) { sleepTimer.isHittable },
                      "Wait for the speed menu dismissal before opening the timer menu.")
        sleepTimer.tap()
        let fortyFiveMinutes = app.buttons["45 minutes"].firstMatch
        XCTAssertTrue(fortyFiveMinutes.waitForExistence(timeout: 3),
                      "The timer menu must show localized text instead of an internal key.")
        fortyFiveMinutes.tap()
        sleepTimer.tap()
        app.buttons["Off"].firstMatch.tap()
        app.buttons["fullPlayer.close"].tap()

        let toc = app.buttons["reader.toc.toggle"].firstMatch
        XCTAssertTrue(toc.waitForExistence(timeout: 5))
        toc.tap()
        for index in 0...1 {
            let download = app.buttons["reader.toc.download.\(index)"].firstMatch
            XCTAssertTrue(download.waitForExistence(timeout: 5))
            XCTAssertTrue(wait(timeout: 90) { download.isEnabled }, "Chapter \(index) must finish producing playable audio.")
            if (download.value as? String)?.lowercased() != "downloaded" { download.tap() }
            XCTAssertTrue(wait(timeout: 20) { (download.value as? String)?.lowercased() == "downloaded" }, "Chapter \(index) must become a retained download.")
        }
        capture(app, name: "physical-two-chapter-downloads-verified")
        app.buttons["Close"].firstMatch.tap()
        app.terminate()
        app.launch()
        let replayOpen = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(replayOpen.waitForExistence(timeout: 20), "Downloaded playback must remain available after relaunch.")
        replayOpen.tap()
        let replayPlay = app.buttons["Play"].firstMatch
        XCTAssertTrue(replayPlay.waitForExistence(timeout: 5), "Relaunch must preserve explicit pause.")
        replayPlay.tap()
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 3))
        let replayBefore = seconds(elapsed.label)
        XCTAssertTrue(wait(timeout: 5) { self.seconds(elapsed.label) != replayBefore },
                      "The retained chapter must resume promptly after app relaunch.")
        let settledReplayClock = seconds(elapsed.label)
        XCTAssertTrue(wait(timeout: 3) { self.seconds(elapsed.label) > settledReplayClock })
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["fullPlayer.nextChapter"].tap()
        XCTAssertTrue(app.staticTexts["Device streaming chapter two"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists)
        app.buttons["fullPlayer.previousChapter"].tap()
        XCTAssertTrue(app.staticTexts["Device streaming chapter one"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists, "Previous downloaded chapter must preserve pause.")
        capture(app, name: "physical-retained-playback-after-relaunch")
        let metrics: [String: Any] = [
            "guiObservedFirstPlaybackSeconds": firstObservedPlaybackSeconds,
            "providerEvidence": "Separate strict live Edge native test; GUI alone does not identify the synthesizer",
            "downloadedChapterIndices": [0, 1],
            "retainedReplayAfterRelaunch": "Playback clock advanced; host verifies no new synthesis job",
            "fixtureCleanup": "Host removes only this dedicated imported EPUB and its artifacts"
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "physical-streaming-controls-downloads.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        return XCTWaiter.wait(for: [condition], timeout: timeout) == .completed
    }

    private func seconds(_ clock: String) -> Int {
        clock.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
