import XCTest

@MainActor
final class PhysicalDeviceStreamingUITests: XCTestCase {
    func testOptInPiperPlaybackNavigationAndPresentation() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_PIPER_MATRIX"] == "1",
              let bookID = ProcessInfo.processInfo.environment["APP_DEVICE_LINK_BOOK_ID"] else {
            throw XCTSkip("Requires the installed authored Portuguese EPUB and authorized Piper playback.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        app.tabBars.buttons["Settings"].tap()
        let table = app.tables.firstMatch
        func reveal(_ element: XCUIElement) {
            for _ in 0..<24 {
                if element.exists && table.frame.insetBy(dx: 0, dy: 12).contains(element.frame) { return }
                if element.exists && element.frame.midY < table.frame.midY { table.swipeDown() }
                else { table.swipeUp() }
            }
            XCTFail("The requested saved preference must be reachable.")
        }
        let primary = app.cells["settings.tts.primary"].firstMatch
        reveal(primary)
        XCTAssertTrue((primary.value as? String ?? "").hasPrefix("Faber"))
        for id in ["settings.tts.automaticSystemFallback", "settings.tts.onlineConsent"] {
            let control = app.switches[id].firstMatch
            reveal(control)
            XCTAssertEqual(control.value as? String, "0", "This journey must not enable another provider.")
        }
        app.tabBars.buttons["Library"].tap()
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15))
        let collection = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if tile.frame.intersection(collection.frame).height >= 80 { break }
            collection.swipeUp()
        }
        let visible = tile.frame.intersection(collection.frame)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: visible.minY + 30)).tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        let miniPlay = app.buttons["miniPlayer.playPause"].firstMatch
        XCTAssertEqual(miniPlay.label.lowercased(), "play", "Opening must not autoplay.")
        miniPlay.tap()
        app.buttons["miniPlayer.open"].firstMatch.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 90))
        let voice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Faber")).firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 120))
        XCTAssertTrue(wait(timeout: 120) { self.seconds(elapsed.label) > 1 })
        capture(app, name: "piper-matrix-playing-faber")
        let transport = app.buttons["fullPlayer.playPause"].firstMatch
        XCTAssertEqual(transport.label.lowercased(), "pause")
        transport.tap()
        XCTAssertTrue(wait(timeout: 5) { transport.label.lowercased() == "play" })
        let paused = seconds(elapsed.label)
        XCUIDevice.shared.press(.home)
        let pauseDelay = expectation(description: "Explicit pause survives background")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pauseDelay.fulfill() }
        wait(for: [pauseDelay], timeout: 5)
        app.activate()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(abs(seconds(elapsed.label) - paused), 1)
        XCTAssertEqual(transport.label.lowercased(), "play")
        app.buttons["fullPlayer.skipForward"].tap()
        XCTAssertTrue(wait(timeout: 90) { self.seconds(elapsed.label) >= paused + 10 })
        XCTAssertEqual(transport.label.lowercased(), "play")
        app.buttons["fullPlayer.skipBack"].tap()
        XCTAssertTrue(wait(timeout: 30) { self.seconds(elapsed.label) <= paused + 2 })
        capture(app, name: "piper-matrix-seek-paused")
        for index in [1, 0] {
            app.buttons[index == 1 ? "fullPlayer.nextChapter" : "fullPlayer.previousChapter"].tap()
            let title = app.staticTexts[index == 1 ? "Destination" : "Origin"].firstMatch
            XCTAssertTrue(title.waitForExistence(timeout: 90))
            XCTAssertEqual(transport.label.lowercased(), "play", "Chapter navigation must retain pause.")
        }
        transport.tap()
        let resumed = seconds(elapsed.label)
        XCTAssertTrue(wait(timeout: 90) { self.seconds(elapsed.label) > resumed + 1 })
        let beforeHome = seconds(elapsed.label)
        XCUIDevice.shared.press(.home)
        let playingDelay = expectation(description: "Prepared playback advances in background")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { playingDelay.fulfill() }
        wait(for: [playingDelay], timeout: 12)
        app.activate()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(seconds(elapsed.label), beforeHome + 5)
        transport.tap()
        XCTAssertTrue(wait(timeout: 5) { transport.label.lowercased() == "play" })
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(wait(timeout: 5) {
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            })
            XCTAssertTrue(wait(timeout: 5) {
                let size = XCUIScreen.main.screenshot().image.size
                return orientation == .portrait ? size.height > size.width : size.width > size.height
            }, "The rendered screen must finish rotating before inspecting player geometry.")
            for id in ["fullPlayer.close", "fullPlayer.playPause", "fullPlayer.skipBack", "fullPlayer.skipForward"] {
                XCTAssertTrue(app.buttons[id].isHittable)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(app.buttons[id].frame))
            }
            capture(app, name: "piper-matrix-player-\(orientation.rawValue)")
        }
        close.tap()
        app.buttons["reader.close"].firstMatch.tap()
        for tab in ["Library", "Settings", "Convert", "Library"] {
            app.tabBars.buttons[tab].tap()
            let mini = app.buttons["miniPlayer.open"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 5))
            let initial = mini.frame
            for sample in 0..<3 {
                let delay = expectation(description: "Observe stable mini-player")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { delay.fulfill() }
                wait(for: [delay], timeout: 2)
                XCTAssertTrue(mini.exists && mini.isHittable)
                XCTAssertEqual(mini.frame.minY, initial.minY, accuracy: 1)
                capture(app, name: "piper-matrix-\(tab)-mini-\(sample)")
            }
        }
    }

    func testOptInPiperManualConversionKeepsPausedPlayback() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_MANUAL_MATRIX"] == "1" else {
            throw XCTSkip("Requires the installed authored EPUBs and authorized physical-device conversion.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        let open = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let miniTransport = app.buttons["miniPlayer.playPause"].firstMatch
        if miniTransport.label.lowercased() == "pause" { miniTransport.tap() }
        XCTAssertEqual(miniTransport.label.lowercased(), "play")
        let listeningIdentity = open.value as? String
        XCTAssertTrue(listeningIdentity?.contains("Reader Live Links") == true)
        app.tabBars.buttons["Convert"].tap()
        let table = app.tables.firstMatch
        func reveal(_ element: XCUIElement) {
            for _ in 0..<16 {
                if element.exists && table.frame.insetBy(dx: 0, dy: 15).contains(element.frame) { return }
                if element.exists && element.frame.midY < table.frame.midY { table.swipeDown() }
                else { table.swipeUp() }
            }
            XCTFail("Manual conversion control must be reachable.")
        }
        let primary = app.cells["convert.tts.primary"].firstMatch
        reveal(primary)
        XCTAssertEqual(primary.value as? String, "Use preferences")
        let picker = app.cells.containing(.staticText, identifier: "Pick EPUB or PDF").firstMatch
        reveal(picker)
        picker.tap()
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 3) { browse.tap() }
        let local = app.cells["DOC.sidebar.item.On My iPhone"].firstMatch
        if !local.waitForExistence(timeout: 3), browse.exists { browse.tap() }
        let browser = app.collectionViews["Browse View"].firstMatch
        for _ in 0..<8 {
            if local.exists && local.isHittable { break }
            browser.swipeUp()
        }
        XCTAssertTrue(local.waitForExistence(timeout: 5), app.debugDescription)
        let settle = expectation(description: "Document browser scrolling has settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { settle.fulfill() }
        wait(for: [settle], timeout: 4)
        local.tap()
        let folder = app.staticTexts["EpubToMp3"].firstMatch
        for _ in 0..<16 {
            if folder.exists && folder.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        folder.tap()
        let source = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@",
            "Piper-Live-Portuguese-20261029", "Piper-Live-Portuguese-20261029.epub")).firstMatch
        for _ in 0..<16 {
            if source.exists && source.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        let selected = app.cells.matching(NSPredicate(format: "value CONTAINS %@", "Piper-Live-Portuguese-20261029.epub")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 10), app.debugDescription)
        let submit = app.cells["convert.submit"].firstMatch
        reveal(submit)
        XCTAssertTrue(submit.isEnabled)
        capture(app, name: "manual-piper-ready")
        submit.tap()
        let completed = app.staticTexts["Conversion completed"].firstMatch
        XCTAssertTrue(wait(timeout: 180) { completed.exists }, app.debugDescription)
        reveal(completed)
        capture(app, name: "manual-piper-completed")
        let result = app.staticTexts["View result"].firstMatch
        reveal(result)
        result.tap()
        let title = app.staticTexts["Piper Live Portuguese"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), app.debugDescription)
        capture(app, name: "manual-piper-local-result")
        XCTAssertTrue(open.exists)
        open.tap()
        let transport = app.buttons["fullPlayer.playPause"].firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        XCTAssertEqual(transport.label.lowercased(), "play", "Manual conversion must retain explicit pause.")
        XCTAssertTrue(app.staticTexts["Reader Live Links"].firstMatch.exists, "The listening book must not be replaced.")
        XCTAssertEqual(listeningIdentity, open.value as? String)
        capture(app, name: "manual-piper-preserved-listening")
    }

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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
