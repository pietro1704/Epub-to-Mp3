#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// Listening with Piper and the screen locked must not exceed the OS background CPU budget: the app asks the
/// Rust loop to pace itself when it leaves the foreground and lifts the limit when it returns.
@MainActor
final class BackgroundSynthesisPacingTests: XCTestCase {
    func testTheLimitFollowsTheApplicationLifecycle() {
        let center = NotificationCenter()
        var applied: [UInt32] = []
        let pacing = BackgroundSynthesisPacing(center: center, isBackgrounded: { false }, setLimit: { applied.append($0) })
        pacing.start()
        XCTAssertTrue(applied.isEmpty, "Foreground at launch: nothing to limit")
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(applied, [50])
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(applied, [50], "A repeat does not call into Rust again")
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(applied, [50, 0], "Coming back lifts the limit")
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(applied, [50, 0, 50, 0])
        pacing.stop()
        XCTAssertEqual(pacing.appliedPercent, 0)
    }

    func testAnAppLaunchedInTheBackgroundStartsPaced() {
        var applied: [UInt32] = []
        let pacing = BackgroundSynthesisPacing(center: NotificationCenter(), isBackgrounded: { true }, setLimit: { applied.append($0) })
        pacing.start()
        XCTAssertEqual(applied, [BackgroundSynthesisPacing.backgroundCPUPercent])
        XCTAssertLessThanOrEqual(BackgroundSynthesisPacing.backgroundCPUPercent, 50, "Well under the 80% OS limit")
    }

    func testTheRealSymbolIsAvailableInTheBundledLibrary() {
        XCTAssertTrue(ConverterFFIAdapter().setBackgroundCPULimit(percent: 0),
                      "The bundled Rust library must export converter_set_background_cpu_limit_v1")
    }
}
#endif
