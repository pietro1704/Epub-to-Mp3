import XCTest

/// VOICE-SWITCH-RESUME-EXACT on a physical iPhone, with real engines and the real library: while listening, every
/// switch of the narration voice (Piper → Piper, Piper → System, System → Piper, Piper → Edge) must keep PLAYING on its
/// own, continue from the same place in the chapter, and never leave the player stuck. The place is judged on the
/// chapter clock's progress ratio (the progress slider's value), which maps to the same text for any voice.
@MainActor
final class VoiceSwitchResumeDeviceUITests: XCTestCase {
    /// The retained "O jardim das Aflicoes" EPUB on the 16e (Piper pt-BR, system pt-BR and Edge are all available).
    private let bookTile = "library.bookTile.ff676d7fa5b703fb8d4c6708fad2d52b"
    private let ratioTolerance = 0.06

    /// `ratio` is the progress slider's position: the chapter clock over the chapter's estimated duration.
    private struct Reading { let elapsed: Double; let ratio: Double }

    func testEveryVoiceSwitchKeepsPlayingFromTheSamePlace() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real engines on a physical iPhone.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-reader.recentTool.v1", "listen",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        var log: [String] = []
        defer {
            let attachment = XCTAttachment(string: log.joined(separator: "\n"))
            attachment.name = "voice-switch-resume-evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let closePlayer = app.buttons["fullPlayer.close"].firstMatch
        if closePlayer.waitForExistence(timeout: 3) { closePlayer.tap() }
        let libraryTab = app.tabBars.buttons["Library"]
        if libraryTab.waitForExistence(timeout: 5) { libraryTab.tap() }
        let tile = app.descendants(matching: .any)[bookTile].firstMatch
        let grid = app.collectionViews.firstMatch
        for _ in 0..<10 where !tile.waitForExistence(timeout: 2) && grid.exists { grid.swipeUp() }
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "The retained Jardim das Aflições EPUB must be in the device library.")
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["reader.more"].firstMatch.waitForExistence(timeout: 90), "The reader must open.")

        let harness = ReaderModesHarness(app: app)
        // Listen from a late page of the chapter, like the reported failure (a chapter clock far from its start):
        // an engine of another speed then has a long way to go before it reaches the old voice's seconds.
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 30))
        for _ in 0..<12 {
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        let toolbarListen = app.navigationBars.buttons["reader.listen"].firstMatch
        XCTAssertTrue(toolbarListen.waitForExistence(timeout: 10), "The reader toolbar must expose Listen.")
        toolbarListen.tap()
        let fromPage = app.buttons["Listen from this page"].firstMatch
        if fromPage.waitForExistence(timeout: 5) { fromPage.tap() }
        let open = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 90), "Listening must show the mini player.")
        open.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let remaining = app.otherElements["fullPlayer.progress"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 240) { self.seconds(elapsed.label) >= 3 }, "Narration must start playing.")
        log.append("START \(read(elapsed, remaining))")

        // Whatever voice the book starts with (the 16e starts on Edge): to Faber, Faber → Cadu (Piper → Piper),
        // Cadu → System (Piper → System), System → Faber (System → Piper) and Faber → Edge (Piper → Edge).
        let steps: [(name: String, matches: (String) -> Bool)] = [
            ("start → Piper (Faber)", { $0.localizedCaseInsensitiveContains("faber") }),
            ("Piper → Piper (Cadu)", { $0.localizedCaseInsensitiveContains("cadu") }),
            ("Piper → System", { $0.localizedCaseInsensitiveContains("system") || $0.localizedCaseInsensitiveContains("sistema") }),
            ("System → Piper (Faber)", { $0.localizedCaseInsensitiveContains("faber") }),
            ("Piper → Edge", { $0.localizedCaseInsensitiveContains("edge") }),
        ]
        for step in steps {
            if !remaining.exists, open.waitForExistence(timeout: 10) { open.tap() }
            XCTAssertTrue(remaining.waitForExistence(timeout: 15), "\(step.name): the full player must be readable")
            let before = read(elapsed, remaining)
            closeFullPlayer(app)
            harness.activateReaderTool(identifier: "reader.voiceModels", title: "Voice models")
            let sheet = app.sheets["reader.voicePicker"].firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "\(step.name): the voice menu must open")
            let choices = sheet.buttons.allElementsBoundByIndex
            let candidates = choices.filter { !$0.label.hasPrefix("✓") && step.matches($0.label) }
            log.append("\(step.name): choices=\(choices.map(\.label))")
            guard let choice = candidates.first else {
                log.append("\(step.name): no matching, not-yet-selected choice; skipped")
                // The picker is a popover without Cancel on this layout: tap outside it.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66)).tap()
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            log.append("\(step.name): choosing \"\(choice.label)\" at \(before)")
            choice.tap()

            // The mini player stays up while the new job prepares.
            XCTAssertTrue(open.waitForExistence(timeout: 90), "\(step.name): the player must stay up")
            open.tap()
            XCTAssertTrue(elapsed.waitForExistence(timeout: 15))
            // It must be PLAYING again without tapping Play, within a generous synthesis window.
            let playing = waitUntil(timeout: 120) {
                let first = self.seconds(elapsed.label)
                Thread.sleep(forTimeInterval: 3)
                return self.seconds(elapsed.label) > first && self.seconds(elapsed.label) > 0
            }
            let after = read(elapsed, remaining)
            attachScreenshot("switch-\(step.name)")
            log.append("\(step.name): playing=\(playing) after=\(after)")
            XCTAssertTrue(playing, "\(step.name): playback must resume on its own")
            XCTAssertEqual(after.ratio, before.ratio, accuracy: ratioTolerance,
                           "\(step.name): must continue from the same place in the chapter")
        }
        #endif
    }

    // MARK: helpers

    private func closeFullPlayer(_ app: XCUIApplication) {
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.exists && close.isHittable {
            close.tap()
            _ = close.waitForNonExistence(timeout: 8)
            Thread.sleep(forTimeInterval: 1.5)
        }
        // The chrome may be hidden by earlier page taps: bring it back so the reader's tools are reachable.
        if !app.buttons["reader.more"].firstMatch.isHittable {
            app.scrollViews["reader.viewport"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func read(_ elapsed: XCUIElement, _ progress: XCUIElement) -> Reading {
        let percent = (progress.value as? String).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) } ?? 0
        return Reading(elapsed: Double(seconds(elapsed.label)), ratio: percent / 100)
    }

    /// "≈ 25:40", "1:02:03" or "About 19:44 remaining" → seconds.
    private func seconds(_ clock: String) -> Int {
        guard let range = clock.range(of: #"\d+(:\d+)+"#, options: .regularExpression) else { return 0 }
        return clock[range].split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 1) }
        return condition()
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
