import XCTest
@testable import EpubToMp3
#if os(iOS)
import UIKit
import MediaPlayer
#endif

@MainActor
final class PlayerViewConfigurationTests: XCTestCase {
    func testExpandedPlayerInstallsCompactSpacingVolumeAndBottomSafeArea() throws {
#if os(iOS)
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let content = FullPlayerContent()
        let action = #selector(UIViewController.viewDidLoad)
        content.install(in: controller.view, actionTarget: controller,
            actions: FullPlayerControlActions(closeTapped: action, scrubBegan: action, scrubChanged: action,
                scrubEnded: action, previousChapterTapped: action, skipBackTapped: action,
                playPauseTapped: action, skipForwardTapped: action, nextChapterTapped: action, tocTapped: action),
            traits: controller.traitCollection)
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.view.subviews.contains { $0 is UIScrollView })
        XCTAssertEqual(content.layoutView.frame.maxY, controller.view.safeAreaLayoutGuide.layoutFrame.maxY, accuracy: 0.5)
        XCTAssertTrue(content.volumeView.showsVolumeSlider)
        XCTAssertTrue(content.volumeView.isDescendant(of: controller.view))
        XCTAssertTrue(content.airPlayView.isDescendant(of: controller.view))
#else
        throw XCTSkip("Expanded UIKit player geometry requires iOS; Simulator execution remains quarantined.")
#endif
    }

    func testUIKitPlayerConsumesMatchingSnapshotAndClockUpdatesWithoutTakingAnotherJob() async throws {
#if os(iOS)
        let suite = "player-view-binding-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        func snapshot(_ id: String, title: String) throws -> JobSnapshot {
            try JSONDecoder().decode(JobSnapshot.self, from: JSONSerialization.data(withJSONObject:
                ["jobId": id, "state": "done", "bookTitle": title]))
        }
        let original = try snapshot("view-owned", title: "Original")
        player.setSnapshot(original)
        let clock = PlaybackClock()
        let controller = PlayerScreenController(snapshot: original, backendBaseURL: nil, player: player, playbackClock: clock)
        controller.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        player.updateSnapshot(try snapshot("view-owned", title: "Updated"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(descendants(controller.view).compactMap { $0 as? UILabel }.contains { $0.text == "Updated" })
        clock.update(positionSeconds: 12, durationSeconds: 60)
        let slider = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CompactSlider }.first)
        XCTAssertEqual(slider.value, 12)
        XCTAssertEqual(slider.maximumValue, 60)
        player.setSnapshot(try snapshot("other-job", title: "Unrelated"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(descendants(controller.view).compactMap { $0 as? UILabel }.contains { $0.text == "Unrelated" })
        XCTAssertEqual(player.snapshot?.jobId, "other-job")
#else
        throw XCTSkip("UIKit playback binding requires iOS; Simulator execution remains quarantined.")
#endif
    }
}
