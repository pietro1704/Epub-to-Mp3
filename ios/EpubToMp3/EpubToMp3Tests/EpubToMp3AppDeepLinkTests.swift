import XCTest
@testable import EpubToMp3

/// Regression tests for the three widget-reported bugs:
///  1. Stale "pause" state in the Now Playing widget (covered in
///     `PlaybackBindingStoreTests` / `WidgetDataSyncTests`).
///  2. Widget play/pause/skip buttons not doing anything.
///  3. Tapping the widget opens the app but never navigates to the player.
///
/// Widget registration and persisted-command policy are exercised through the
/// native application seam. Retained bundle source checks describe wiring;
/// they do not establish actual notification delivery or rendered appearance.
final class EpubToMp3AppDeepLinkTests: XCTestCase {

    private func appSource() throws -> String {
        try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/EpubToMp3App.swift")
        )
    }

    private func widgetBundleSource() throws -> String {
        try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3Widget/WidgetBundle.swift")
        )
    }

    // MARK: - Bug 3: deep link must navigate to the player, not just open the app

    /// Regression: `epubtomp3://player?bookId=...` used to only set
    /// `currentlyReadingBookID` / `currentlyPlayingBookID` in UserDefaults —
    /// nothing ever called `playerPresentation.showFullPlayer()`, so the
    /// widget tap opened the app to the Library/reader landing screen
    /// instead of the player sheet.
    func testPlayerDeepLinkCallsShowFullPlayer() throws {
        let source = try appSource()
        guard let caseRange = source.range(of: "components.host == \"player\"") else {
            XCTFail("handleIncomingURL must still have a player deep-link branch")
            return
        }
        // Look at the player branch body only.
        let afterCase = source[caseRange.upperBound...]
        let nextCaseRange = afterCase.range(of: "}\n")
        let body = nextCaseRange != nil ? afterCase[..<nextCaseRange!.lowerBound] : afterCase

        XCTAssertTrue(
            body.contains("playerPresentation.showFullPlayer()"),
            "The \"player\" deep-link case must call playerPresentation.showFullPlayer() so tapping the widget actually navigates to the player, not just opens the app."
        )
    }

    // MARK: - Bug 2: widget buttons must reach AudioPlayer even while backgrounded

    /// Regression: widget play/pause/skip taps wrote a UserDefaults flag
    /// that was only drained on a `scenePhase` transition to `.active`.
    /// If the app was already foregrounded/backgrounded (not suspended —
    /// it declares the `audio` UIBackgroundMode), the flag was never
    /// drained and the button appeared to do nothing. Fixed by also
    /// posting + observing a Darwin notification.
    @MainActor
    func testAppRegistersDarwinNotificationObserverForWidgetIntents() throws {
        var registrations = 0
        ApplicationWidgetIntents.registerObserver(isRunningUnderTests: false) { registrations += 1 }
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(ApplicationWidgetIntents.notificationName, "com.pietrocode.epubtomp3.widgetIntent")
    }

    // Persisted-command ordering, cover downsampling and provider identity
    // are covered by WidgetSnapshotTests at the native runtime.

    func testWidgetBundleRegistersLockScreenWidget() throws {
        let source = try widgetBundleSource()
        XCTAssertTrue(source.contains("NowPlayingLockScreenWidget()"))
        XCTAssertTrue(source.contains("iOS 16.1"))
    }

    // MARK: - Bug 2: observer registration must be skipped under XCTest

    /// A process-wide observer must not outlive an XCTest-hosted application.
    @MainActor
    func testRegisterWidgetIntentObserverGuardsAgainstXCTestHost() throws {
        var registrations = 0
        ApplicationWidgetIntents.registerObserver(isRunningUnderTests: true) { registrations += 1 }
        XCTAssertEqual(registrations, 0)
    }
}
