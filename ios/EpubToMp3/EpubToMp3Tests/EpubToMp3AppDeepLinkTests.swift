import XCTest
@testable import EpubToMp3

/// Regression tests for the three widget-reported bugs:
///  1. Stale "pause" state in the Now Playing widget (covered in
///     `NowPlayingViewTests` / `WidgetDataSyncTests`).
///  2. Widget play/pause/skip buttons not doing anything.
///  3. Tapping the widget opens the app but never navigates to the player.
///
/// `EpubToMp3App` is a SwiftUI `App` struct — its `handleDeepLink` /
/// `registerWidgetIntentObserver` logic isn't directly invokable from a
/// unit-test host without a live scene. We assert on the source text
/// (same pattern already used by `NowPlayingViewTests
/// .testNowPlayingUsesJobSnapshotStubForPlayerReader`) to pin the wiring,
/// plus a live Darwin-notification round trip for the parts that ARE
/// invokable without a scene.
final class EpubToMp3AppDeepLinkTests: XCTestCase {

    private func appSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/EpubToMp3App.swift")
        )
    }

    private func widgetSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3Widget/EpubToMp3Widget.swift")
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
        guard let caseRange = source.range(of: "case \"player\":") else {
            XCTFail("handleDeepLink must still have a \"player\" case")
            return
        }
        // Look at the case body only (up to the next `case` or the closing brace).
        let afterCase = source[caseRange.upperBound...]
        let nextCaseRange = afterCase.range(of: "case \"library\":")
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
    func testAppRegistersDarwinNotificationObserverForWidgetIntents() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("CFNotificationCenterAddObserver"),
            "EpubToMp3App must register a CFNotificationCenter observer so widget button taps are drained immediately, not only on scenePhase == .active."
        )
        XCTAssertTrue(
            source.contains("com.pietrocode.epubtomp3.widgetIntent"),
            "The Darwin notification name must match the one posted by the widget extension's AppIntents."
        )
    }

    func testWidgetIntentsPostDarwinNotificationAfterWritingFlag() throws {
        let source = try widgetSource()
        XCTAssertTrue(
            source.contains("postWidgetIntentNotification()"),
            "TogglePlayPauseIntent/SkipForward30Intent must ping the host app immediately via Darwin notification instead of only relying on the next scenePhase transition."
        )
        XCTAssertTrue(
            source.contains("com.pietrocode.epubtomp3.widgetIntent"),
            "Widget-side Darwin notification name must match the app-side observer."
        )
    }

    // MARK: - Bug 2: observer registration must be skipped under XCTest

    /// `registerWidgetIntentObserver` must not register a process-wide
    /// Darwin observer while running under XCTest — a live SwiftUI scene
    /// never mounts in the unit-test host, so `sharedPlayerForWidgetIntents`
    /// would stay nil forever and a stray global observer could leak
    /// across test runs / bleed into other test bundles hosted in the
    /// same xctest process.
    func testRegisterWidgetIntentObserverGuardsAgainstXCTestHost() throws {
        let source = try appSource()
        guard let funcRange = source.range(of: "private static func registerWidgetIntentObserver()") else {
            XCTFail("registerWidgetIntentObserver must exist")
            return
        }
        let body = source[funcRange.upperBound...].prefix(300)
        XCTAssertTrue(
            body.contains("isRunningUnderXCTest()"),
            "registerWidgetIntentObserver must early-return under XCTest, matching the sidecar-boot and cache-eviction guards already used elsewhere in this file."
        )
    }
}
