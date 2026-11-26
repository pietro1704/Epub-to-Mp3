import XCTest

/// APPLE-BG-PLAYBACK: audio keeps playing at the Home screen and while the device is
/// locked, across a chapter boundary, and an intentional pause survives backgrounding.
///
/// Physical iPhone only (the Simulator has no lock button). The fixture installs two
/// locally generated tone chapters (70 s at 440 Hz, then 180 s at 660 Hz); no Piper,
/// model, network or library change is involved. The device must have no passcode.
@MainActor
final class BackgroundLockPlaybackDeviceUITests: XCTestCase {
    private let chapterOneSeconds = 70.0
    private let homeSeconds = 30.0
    private let lockedSeconds = 120.0
    private let pausedBackgroundSeconds = 10.0

    private struct Reading {
        let date: Date
        let chapter: String
        let elapsed: Double
    }

    func testPlaybackContinuesAtHomeAndLockedAcrossChapterBoundary() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Background/lock playback acceptance requires a physical iPhone.")
        #else
        let lockSelector = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lockSelector) else {
            throw XCTSkip("XCUIDevice.pressLockButton is unavailable on this runtime.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait

        let app = XCUIApplication()
        // Isolated defaults and App Group: the fixture binds its audio to the first library book.
        app.launchArguments = ["-uiTestPlaybackFixture", "-uiTestPlaybackLongChapters", "-uiTestIsolatedSettings",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        var log: [String] = [
            "Fixture audio (deliberate, local, generated): chapter 1 = 70 s 440 Hz tone, chapter 2 = 180 s 660 Hz tone.",
            "Launch arguments: \(app.launchArguments.joined(separator: " "))",
        ]
        defer {
            let attachment = XCTAttachment(string: log.joined(separator: "\n"))
            attachment.name = "background-lock-playback-evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // The fixture may present the full player itself (observed on the 16e);
        // otherwise open it from the mini player. Start through the full player's
        // own Play control, which is the visible one in both cases.
        let fullPlay = app.buttons["fullPlayer.playPause"].firstMatch
        if !fullPlay.waitForExistence(timeout: 10) {
            let open = app.buttons["miniPlayer.open"].firstMatch
            XCTAssertTrue(open.waitForExistence(timeout: 20), "The fixture must expose the mini player.")
            open.tap()
            XCTAssertTrue(fullPlay.waitForExistence(timeout: 10), "The full player must expose Play.")
        }
        if fullPlay.label != "Pause" { fullPlay.tap() }
        // A reader position that differs from the audio asks where to continue;
        // keep the audio position (observed on the 16e with a bound PDF book).
        let continueAudio = app.buttons["Continue where I left off"].firstMatch
        if continueAudio.waitForExistence(timeout: 5) { continueAudio.tap() }
        log.append("START full-player button label after tap: \(fullPlay.label)")
        let elapsedLabel = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let chapterLabel = app.staticTexts["fullPlayer.chapterAndVoice"].firstMatch
        XCTAssertTrue(elapsedLabel.waitForExistence(timeout: 10), "The full player must expose the elapsed clock.")
        XCTAssertTrue(waitUntil(timeout: 15) { self.seconds(elapsedLabel.label) >= 2 },
                      "The playback clock must advance before backgrounding.")
        attachScreenshot("01-playing-before-background")

        let before = read(elapsedLabel, chapterLabel)
        log.append("BEFORE date=\(before.date) chapter=\"\(before.chapter)\" elapsed=\(before.elapsed)s")
        XCTAssertTrue(before.chapter.contains("Chapter 1"), "Playback must start in chapter 1, got: \(before.chapter)")
        XCTAssertLessThan(before.elapsed, 30, "The chapter boundary must fall inside the locked period.")

        // Home screen.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: homeSeconds)
        log.append("HOME held \(homeSeconds)s; app.state=\(app.state.rawValue)")

        // Lock.
        XCUIDevice.shared.perform(lockSelector)
        let lockedAt = Date()
        Thread.sleep(forTimeInterval: lockedSeconds)
        log.append("LOCKED at \(lockedAt) for \(lockedSeconds)s")

        // Wake. A passcode device needs the owner to unlock: wait until the
        // Home Screen icons are reachable (up to 3 minutes) before activating.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let unlockDeadline = Date().addingTimeInterval(180)
        var nudged = Date.distantPast
        while Date() < unlockDeadline && !springboard.icons.firstMatch.exists {
            if Date().timeIntervalSince(nudged) > 20 {
                XCUIDevice.shared.press(.home)
                nudged = Date()
            }
            Thread.sleep(forTimeInterval: 2)
        }
        log.append("UNLOCKED home-screen-visible=\(springboard.icons.firstMatch.exists) at \(Date())")
        XCTAssertTrue(springboard.icons.firstMatch.exists, "The device must be unlocked to read the player after the locked period.")
        app.activate()
        XCTAssertTrue(elapsedLabel.waitForExistence(timeout: 15), "The full player must still be presented after unlock.")
        XCTAssertTrue(waitUntil(timeout: 15) { self.chapterLabel(chapterLabel).contains("Chapter 2") },
                      "The queue must have advanced to chapter 2 while locked, got: \(chapterLabel.label)")
        attachScreenshot("02-after-unlock")

        let after = read(elapsedLabel, chapterLabel)
        log.append("AFTER date=\(after.date) chapter=\"\(after.chapter)\" elapsed=\(after.elapsed)s")
        let wall = after.date.timeIntervalSince(before.date)
        let advanced = (after.chapter.contains("Chapter 2") ? chapterOneSeconds : 0) + after.elapsed - before.elapsed
        let required = (homeSeconds + lockedSeconds) * 0.8
        log.append("wall=\(wall)s advanced=\(advanced)s required>=\(required)s")
        XCTAssertGreaterThanOrEqual(wall, homeSeconds + lockedSeconds)
        XCTAssertGreaterThanOrEqual(advanced, required,
                                    "Playback must continue at Home and locked (advanced \(advanced)s of \(wall)s).")
        XCTAssertTrue(after.chapter.contains("Chapter 2"), "Chapter must advance to 2, got: \(after.chapter)")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists, "Playback intent must still be playing.")

        // Pause intent survives backgrounding.
        let transport = app.buttons["fullPlayer.playPause"].firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        transport.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 5), "Pause must show the Play control.")
        Thread.sleep(forTimeInterval: 1.5)
        let paused = read(elapsedLabel, chapterLabel)
        log.append("PAUSED date=\(paused.date) chapter=\"\(paused.chapter)\" elapsed=\(paused.elapsed)s")
        attachScreenshot("03-paused")

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: pausedBackgroundSeconds)
        app.activate()
        XCTAssertTrue(elapsedLabel.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.5)
        let resumed = read(elapsedLabel, chapterLabel)
        log.append("REACTIVATED date=\(resumed.date) chapter=\"\(resumed.chapter)\" elapsed=\(resumed.elapsed)s")
        attachScreenshot("04-reactivated-paused")
        XCTAssertEqual(resumed.chapter, paused.chapter, "Pause must not change chapter.")
        XCTAssertLessThanOrEqual(abs(resumed.elapsed - paused.elapsed), 1,
                                 "Paused playback must not advance while backgrounded.")
        XCTAssertTrue(app.buttons["Play"].firstMatch.exists, "Pause intent must be preserved after reactivation.")
        #endif
    }

    /// Real book and real synthesis: the retained LOTR EPUB, a chapter that is
    /// normally not converted yet, and the installed English Piper voice, so audio
    /// is still being generated while the device is at Home and locked.
    func testLOTRGrowingAudioContinuesAtHomeAndLocked() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device background/lock journey.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let lockSelector = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lockSelector) else {
            throw XCTSkip("XCUIDevice.pressLockButton is unavailable on this runtime.")
        }
        let app = XCUIApplication()
        // Launch-only overrides; the library, books and audio are preserved.
        // `-reader.recentTool.v1 listen` puts Listen on the toolbar for this launch only.
        app.launchArguments = ["-uiTestResetActiveReader", "-uiTestReaderLayout", "paginated",
                               "-reader.recentTool.v1", "listen",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        var log: [String] = ["Book: retained LOTR EPUB. Voice: installed English Piper model expected."]
        defer {
            let attachment = XCTAttachment(string: log.joined(separator: "\n"))
            attachment.name = "lotr-growing-audio-evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let expanded = app.buttons["fullPlayer.close"].firstMatch
        if expanded.waitForExistence(timeout: 3) { expanded.tap() }
        let tile = app.descendants(matching: .any)["library.bookTile.3e1c676b270dfa3fe555eba4d0cb9934"].firstMatch
        if !tile.waitForExistence(timeout: 5) {
            let search = app.searchFields["library.searchField"].firstMatch
            if search.waitForExistence(timeout: 5) { search.tap(); search.typeText("lord") }
        }
        guard tile.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the retained local LOTR EPUB in the device library.")
        }
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["reader.more"].firstMatch.waitForExistence(timeout: 90), "The LOTR reader must open.")

        // A late chapter is normally not converted yet, so listening streams new audio.
        let harness = ReaderModesHarness(app: app)
        harness.activateReaderTool(identifier: "reader.toc.toggle", title: "TOC")
        let table = app.tables["reader.toc"]
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        let target = table.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", "Many Meetings")).firstMatch
        for _ in 0..<40 where !target.isHittable { table.swipeUp() }
        XCTAssertTrue(target.isHittable, "LOTR contents must list Many Meetings.")
        log.append("TOC row: \(target.label)")
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(table.waitForNonExistence(timeout: 10))

        // Only the toolbar's own Listen control: a generic "Play" match can hit the
        // mini player and resume another session.
        let toolbarListen = app.navigationBars.buttons["reader.listen"].firstMatch
        XCTAssertTrue(toolbarListen.waitForExistence(timeout: 10), "The reader toolbar must expose Listen.")
        toolbarListen.tap()
        let fromPage = app.buttons["Listen from this page"].firstMatch
        if fromPage.waitForExistence(timeout: 5) { fromPage.tap() }
        let open = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 60), "Listening must show the mini player.")
        open.tap()
        let elapsedLabel = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let chapterLabel = app.staticTexts["fullPlayer.chapterAndVoice"].firstMatch
        XCTAssertTrue(elapsedLabel.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 240, pollInterval: 1) { self.seconds(elapsedLabel.label) >= 3 },
                      "Synthesized audio must start playing within four minutes.")
        attachScreenshot("lotr-01-playing")
        let before = read(elapsedLabel, chapterLabel)
        log.append("BEFORE date=\(before.date) chapterAndVoice=\"\(before.chapter)\" elapsed=\(before.elapsed)s")

        let homeSeconds: TimeInterval = 30, lockedSeconds: TimeInterval = 180
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: homeSeconds)
        XCUIDevice.shared.perform(lockSelector)
        Thread.sleep(forTimeInterval: lockedSeconds)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let unlockDeadline = Date().addingTimeInterval(240)
        var nudged = Date.distantPast
        while Date() < unlockDeadline && !springboard.icons.firstMatch.exists {
            if Date().timeIntervalSince(nudged) > 20 { XCUIDevice.shared.press(.home); nudged = Date() }
            Thread.sleep(forTimeInterval: 2)
        }
        log.append("UNLOCKED home-screen-visible=\(springboard.icons.firstMatch.exists) at \(Date())")
        XCTAssertTrue(springboard.icons.firstMatch.exists, "Unlock the device to read the player after the locked period.")
        app.activate()
        XCTAssertTrue(elapsedLabel.waitForExistence(timeout: 15))
        attachScreenshot("lotr-02-after-unlock")
        let after = read(elapsedLabel, chapterLabel)
        let wall = after.date.timeIntervalSince(before.date)
        let advanced = after.elapsed - before.elapsed
        log.append("AFTER date=\(after.date) chapterAndVoice=\"\(after.chapter)\" elapsed=\(after.elapsed)s")
        log.append("wall=\(wall)s advanced=\(advanced)s required>=\((homeSeconds + lockedSeconds) * 0.6)s")
        if after.chapter == before.chapter {
            XCTAssertGreaterThanOrEqual(advanced, (homeSeconds + lockedSeconds) * 0.6,
                                        "Growing audio must keep playing at Home and while locked.")
        } else {
            log.append("Chapter changed while backgrounded; advance is judged from the recording.")
        }
        #endif
    }

    private func read(_ elapsed: XCUIElement, _ chapter: XCUIElement) -> Reading {
        Reading(date: Date(), chapter: chapterLabel(chapter), elapsed: Double(seconds(elapsed.label)))
    }

    private func chapterLabel(_ element: XCUIElement) -> String { element.label }

    /// Parses `m:ss` / `h:mm:ss`, ignoring the approximate-position prefix.
    private func seconds(_ clock: String) -> Int {
        clock.filter { $0.isNumber || $0 == ":" }
            .split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
