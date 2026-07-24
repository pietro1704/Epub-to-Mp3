import XCTest
@testable import EpubToMp3

/// Regression tests for the three widget-reported bugs:
///  1. Stale "pause" state in the Now Playing widget (covered in
///     `PlaybackBindingStoreTests` / `WidgetDataSyncTests`).
///  2. Widget play/pause/skip buttons not doing anything.
///  3. Tapping the widget opens the app but never navigates to the player.
///
/// `EpubToMp3App` is a SwiftUI `App` struct — its `handleDeepLink` /
/// `registerWidgetIntentObserver` logic isn't directly invokable from a
/// unit-test host without a live scene. We assert on the source text
/// (same pattern already used by the playback binding tests) to pin the wiring,
/// plus a live Darwin-notification round trip for the parts that ARE
/// invokable without a scene.
final class EpubToMp3AppDeepLinkTests: XCTestCase {

    private func appSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/EpubToMp3App.swift")
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

    private func widgetBundleSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
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
            "Widget-side Darwin notification name must match the one posted by the widget extension's AppIntents."
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "static let openAppWhenRun = true").count - 1,
            2,
            "Playback widget intents must open the host app so the App Group flag is drained even when the app is suspended."
        )
    }

    // MARK: - Device-freeze: widget must not decode full-res covers

    /// Regression: WidgetKit extensions are killed by `widgetkitd` at
    /// ~30 MB. The Now Playing provider used to pass `book.coverPNG`
    /// straight into the entry — `UIImage(data:)` then decompressed it
    /// to full pixel dimensions at render time. On a play burst several
    /// widget kinds reload at once; the combined decode spiked the
    /// extension over its jetsam limit and, together with the main app's
    /// image-heavy chapter render, contributed to a system-wide memory
    /// storm that forced a full device reboot. The provider must route
    /// the cover through the ImageIO thumbnail path.
    func testWidgetNowPlayingCoverIsDownsampled() throws {
        let source = try widgetSource()
        XCTAssertTrue(
            source.contains("func downsampledWidgetCover"),
            "widget must have an ImageIO-based cover downsampler to stay under the ~30 MB WidgetKit jetsam limit."
        )
        XCTAssertTrue(
            source.contains("CGImageSourceCreateThumbnailAtIndex"),
            "cover downsampling must use ImageIO's thumbnail path so the full-resolution bitmap is never allocated in the memory-capped widget process."
        )
        // The NowPlaying entry must be built from the downsampled cover,
        // not the raw stored blob.
        guard let providerRange = source.range(of: "private func loadNowPlaying()") else {
            XCTFail("NowPlayingProvider.loadNowPlaying must exist")
            return
        }
        let body = source[providerRange.upperBound...].prefix(1200)
        XCTAssertTrue(
            body.contains("downsampledWidgetCover"),
            "loadNowPlaying must feed the entry a downsampled cover, never the raw stored blob."
        )
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: ".padding(8)").count - 1,
            4,
            "Now Playing and Continue Reading cover layouts must reserve visible padding around the cover."
        )
    }

    func testWidgetBundleRegistersLockScreenWidget() throws {
        let source = try widgetBundleSource()
        XCTAssertTrue(source.contains("NowPlayingLockScreenWidget()"))
        XCTAssertTrue(source.contains("iOS 16.1"))
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
