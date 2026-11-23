import XCTest
@testable import EpubToMp3
#if os(iOS)
import UIKit
import MediaPlayer
#endif

@MainActor
final class PlayerViewConfigurationTests: XCTestCase {
#if os(iOS)
    func testCoverActionIsAccessibleAndDispatchesToItsTarget() {
        let target = CoverActionTarget()
        let controller = UIViewController()
        let content = FullPlayerContent()
        let action = #selector(CoverActionTarget.tapped)
        content.install(in: controller.view, actionTarget: target,
                        actions: .init(closeTapped: action, scrubBegan: action, scrubChanged: action, scrubEnded: action,
                            previousChapterTapped: action, skipBackTapped: action, playPauseTapped: action,
                            skipForwardTapped: action, nextChapterTapped: action, tocTapped: action, coverTapped: action),
                        traits: controller.traitCollection)
        XCTAssertTrue(content.coverButton.isDescendant(of: content.coverContainer))
        XCTAssertEqual(content.coverButton.accessibilityIdentifier, "fullPlayer.openReader")
        content.coverButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(target.taps, 1)
    }

    func testUnalignedPlaybackPositionAccountsForPartialChapterAudio() {
        XCTAssertEqual(ReaderPlaybackLocation.estimatedOffset(
            seconds: 30, duration: 60, textOffset: 20, sourceCount: 100, renderedCount: 200), 120)
        XCTAssertEqual(ReaderPlaybackLocation.estimatedOffset(
            seconds: .nan, duration: 0, textOffset: 20, sourceCount: 100, renderedCount: 200), 40)
    }

    func testCoverUsesReaderChapterForOneBasedFilesAndSegments() throws {
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
            {
                "jobId": "legacy-cover-position",
                "state": "finished",
                "chapterIndexBase": 1,
                "chapterProgress": [{
                    "index": 4, "name": "Chapter Four", "status": "completed",
                    "downloadUrl": "file:///tmp/legacy-cover-position.mp3"
                }]
            }
            """.utf8))
        let player = AudioPlayer()
        player.setSnapshot(snapshot)
        player.services.observation.publishCurrentChapter()
        XCTAssertEqual(player.activeStreamingChapterIndex, 4)
        XCTAssertEqual(ReaderPlaybackLocation(player: player)?.chapterIndex, 3)

        player.playbackSegmentModeChanged(true)
        player.services.observation.publishCurrentChapter()
        XCTAssertEqual(player.activeStreamingChapterIndex, 0)
        XCTAssertEqual(ReaderPlaybackLocation(player: player)?.chapterIndex, 0)
    }

    private final class CoverActionTarget: NSObject {
        var taps = 0
        @objc func tapped() { taps += 1 }
    }
#endif

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
        let clock = player.playbackClock
        let controller = PlayerScreenController(snapshot: original, backendBaseURL: nil, player: player)
        controller.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        player.updateSnapshot(try snapshot("view-owned", title: "Updated"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(descendants(controller.view).compactMap { $0 as? UILabel }.contains { $0.text == "Updated" })
        clock.update(positionSeconds: 12, durationSeconds: 60)
        try await Task.sleep(nanoseconds: 20_000_000)
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
