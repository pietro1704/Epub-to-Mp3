#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class VoiceModelSettingsNavigationTests: XCTestCase {
    func testModelsRowPushesTheModelsScreenAndReturnsWithoutInlineExpansion() throws {
        let suite = "VoiceNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let library = LibraryStore(defaults: defaults)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let root = SettingsScreenController(settings: settings, library: library, player: player,
            playbackClock: PlaybackClock())
        let navigation = UINavigationController(rootViewController: root)
        navigation.loadViewIfNeeded()
        root.loadViewIfNeeded()
        let runtime = SettingsSection.runtime.rawValue
        XCTAssertEqual(root.tableView(root.tableView, numberOfRowsInSection: runtime), 1)
        root.tableView(root.tableView, didSelectRowAt: IndexPath(row: 0, section: runtime))
        let detail = try XCTUnwrap(navigation.topViewController as? ModelsScreenController,
                                   "The single Models row opens the Models screen")
        detail.loadViewIfNeeded()
        XCTAssertEqual(detail.title, L10n.string("models.title"))
        settings.selectSecondaryNarration(nil)
        navigation.popViewController(animated: false)
        XCTAssertTrue(navigation.topViewController === root)
        XCTAssertEqual(root.tableView(root.tableView, numberOfRowsInSection: runtime), 1)
        XCTAssertNil(settings.ttsPreferences.secondary)
        XCTAssertEqual(settings.primaryEngine, TtsSelection.piperEngine)
    }
}
#elseif os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacVoiceModelSettingsNavigationTests: XCTestCase {
    func testVoiceModelsUseASeparateDetailAndNativeBackPreservesPreferences() throws {
        let suite = "MacVoiceNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let root = MacSettingsViewController(settings: settings, library: LibraryStore(defaults: defaults))
        _ = root.view
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let models = try XCTUnwrap(descendants(root.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "settings.speechModels.disclosure" })
        XCTAssertTrue(root.children.isEmpty)
        models.performClick(nil)
        let detail = try XCTUnwrap(root.children.first as? MacSettingsDetailNavigation)
        let child = try XCTUnwrap(detail.children.first as? MacModelsViewController,
                                  "The single Models button opens the Models screen")
        XCTAssertEqual(child.title, L10n.string("models.title"))
        let back = try XCTUnwrap(descendants(detail.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "settings.voiceModels.back" })
        back.performClick(nil)
        XCTAssertTrue(root.children.isEmpty)
        XCTAssertFalse(models.isHidden)
        XCTAssertEqual(settings.primaryEngine, TtsSelection.piperEngine)
    }
}
#endif
