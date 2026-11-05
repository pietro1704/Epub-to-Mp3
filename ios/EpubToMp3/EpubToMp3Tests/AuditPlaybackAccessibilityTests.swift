#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class AuditPlaybackAccessibilityTests: XCTestCase {
    func testChapterAndContentsControlsKeepLocalizedNamesWhenDisabled() throws {
        let suite = "audit-playback-labels-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        let controller = FullPlayerScreenController(player: player, playbackClock: PlaybackClock(),
            library: LibraryStore(defaults: defaults), playerPresentation: PlayerPresentation(defaults: defaults),
            settings: AppSettings(defaults: defaults), onStartListening: {})
        controller.loadViewIfNeeded()
        let controls = descendants(controller.view).compactMap { $0 as? UIButton }
        for (identifier, key) in [("fullPlayer.previousChapter", "player.previousChapter"),
                                  ("fullPlayer.nextChapter", "player.nextChapter"),
                                  ("fullPlayer.tableOfContents", "player.toc")] {
            let button = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == identifier })
            for enabled in [false, true] {
                button.isEnabled = enabled
                XCTAssertEqual(button.accessibilityLabel, L10n.string(key))
                XCTAssertNotEqual(button.accessibilityLabel, "TOC")
            }
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
