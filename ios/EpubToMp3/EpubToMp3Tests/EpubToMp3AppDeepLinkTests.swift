import XCTest
@testable import EpubToMp3

/// Regression tests for the three widget-reported bugs:
///  1. Stale "pause" state in the Now Playing widget (covered in
///     `PlaybackBindingStoreTests` / `WidgetDataSyncTests`).
///  2. Widget play/pause/skip buttons not doing anything.
///  3. Tapping the widget opens the app but never navigates to the player.
///
/// Widget registration and persisted-command policy are exercised through the
/// native application seam.
final class EpubToMp3AppDeepLinkTests: XCTestCase {

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

    // MARK: - Bug 2: observer registration must be skipped under XCTest

    /// A process-wide observer must not outlive an XCTest-hosted application.
    @MainActor
    func testRegisterWidgetIntentObserverGuardsAgainstXCTestHost() throws {
        var registrations = 0
        ApplicationWidgetIntents.registerObserver(isRunningUnderTests: true) { registrations += 1 }
        XCTAssertEqual(registrations, 0)
    }
}
