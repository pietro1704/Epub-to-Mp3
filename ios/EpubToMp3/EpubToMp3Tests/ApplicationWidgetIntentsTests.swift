import Foundation
import XCTest
@testable import EpubToMp3

@MainActor
final class ApplicationWidgetIntentsTests: XCTestCase {
    func testPendingCommandsAreConsumedOnceAndLeaveUnrelatedIdentityUntouched() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "widget.intent.togglePlayPause")
        defaults.set(true, forKey: "widget.intent.skipForward30")
        defaults.set("selected-book", forKey: "intent.pendingBookId")
        var toggles = 0
        var skips = 0
        for _ in 0..<2 {
            ApplicationWidgetIntents.consumePendingActions(
                defaults: defaults,
                togglePlayPause: { toggles += 1 },
                skipForward: { skips += 1 }
            )
        }
        XCTAssertEqual(toggles, 1)
        XCTAssertEqual(skips, 1)
        XCTAssertNil(defaults.object(forKey: "widget.intent.togglePlayPause"))
        XCTAssertNil(defaults.object(forKey: "widget.intent.skipForward30"))
        XCTAssertEqual(defaults.string(forKey: "intent.pendingBookId"), "selected-book")
    }

    func testMissingOrFalseCommandsDoNotReachPlayback() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "widget.intent.togglePlayPause")
        ApplicationWidgetIntents.consumePendingActions(
            defaults: defaults,
            togglePlayPause: { XCTFail("A false command must not toggle playback") },
            skipForward: { XCTFail("A missing command must not skip playback") }
        )
    }
}
