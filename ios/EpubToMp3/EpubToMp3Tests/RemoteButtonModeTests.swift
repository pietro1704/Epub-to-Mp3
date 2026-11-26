import XCTest
@testable import EpubToMp3

/// REMOTE-BUTTON-MODE: what the external next / previous buttons (car, headphones, lock screen) do.
final class RemoteButtonModeTests: XCTestCase {
    private func freshDefaults() throws -> (UserDefaults, String) {
        let name = "remote-button-mode-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testDefaultIsChapterNavigation() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(RemoteButtonMode.stored(in: defaults), .chapter)
        defaults.set("nonsense", forKey: RemoteButtonMode.storageKey)
        XCTAssertEqual(RemoteButtonMode.stored(in: defaults), .chapter, "An unknown stored value falls back to the default")
    }

    func testChapterModeKeepsNextAndPreviousAsChapterNavigation() {
        XCTAssertEqual(RemoteButtonMode.chapter.resolve(forward: true, forwardSeconds: 45, backwardSeconds: 15), .chapter(forward: true))
        XCTAssertEqual(RemoteButtonMode.chapter.resolve(forward: false, forwardSeconds: 45, backwardSeconds: 15), .chapter(forward: false))
    }

    /// A head unit that only sends track commands must still skip by the configured number of seconds.
    func testSkipModeMapsNextAndPreviousToTheConfiguredSeconds() {
        XCTAssertEqual(RemoteButtonMode.skip.resolve(forward: true, forwardSeconds: 45, backwardSeconds: 15), .skip(45))
        XCTAssertEqual(RemoteButtonMode.skip.resolve(forward: false, forwardSeconds: 45, backwardSeconds: 30), .skip(-30))
    }

    func testTheChoiceIsPersistedByAppSettings() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.remoteButtonMode, .chapter)
        settings.remoteButtonMode = .skip
        XCTAssertEqual(RemoteButtonMode.stored(in: defaults), .skip)
        XCTAssertEqual(AppSettings(defaults: defaults).remoteButtonMode, .skip, "It survives a relaunch")
    }

    func testEveryLocaleNamesTheSettingAndBothChoices() {
        for key in ["settings.remoteButtons", "settings.remoteButtons.chapter", "settings.remoteButtons.skip"] {
            for localization in ["en", "pt-BR", "es"] {
                let bundle = L10n.localizationBundle(localization)
                XCTAssertNotEqual(L10n.string(key, bundle: bundle), key, "\(key) is missing in \(localization)")
            }
        }
    }
}

#if os(iOS)
import UIKit

/// The iOS Settings > Playback row for the setting (UIKit presentation; verified on the iPhone 16e).
@MainActor
final class RemoteButtonModeRowTests: XCTestCase {
    func testPlaybackSectionHasARemoteButtonsRowThatShowsTheCurrentChoice() throws {
        let name = "remote-button-row-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let table = UITableView()
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        let rows = PlaybackSettingsRows(tableView: table, settings: settings)
        XCTAssertEqual(SettingsSection.playback.rowCount, 3)

        let cell = rows.cell(for: IndexPath(row: 2, section: 0))
        XCTAssertEqual(cell.accessibilityIdentifier, "settings.remoteButtons")
        var content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.text, L10n.string("settings.remoteButtons"))
        XCTAssertEqual(content.secondaryText, RemoteButtonMode.chapter.title)

        settings.remoteButtonMode = .skip
        content = try XCTUnwrap(rows.cell(for: IndexPath(row: 2, section: 0)).contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.secondaryText, RemoteButtonMode.skip.title)
        XCTAssertEqual(rows.cell(for: IndexPath(row: 0, section: 0)).accessibilityIdentifier, "settings.skipForward",
                       "The skip-interval rows keep their place")
    }
}
#endif

/// AIRPODS-BACK-PRESS and REMOTE-JUMP-LOSES-FOLLOW: the path behind the system's next/previous-track commands.
@MainActor
final class RemoteTrackCommandPathTests: XCTestCase {
    private var previousValues: [String: Any] = [:]
    private let keys = [RemoteButtonMode.storageKey, AppSettings.playbackForwardSecondsKey,
                        AppSettings.playbackBackwardSecondsKey]

    override func setUp() {
        super.setUp()
        previousValues = [:]
        for key in keys { previousValues[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(30.0, forKey: AppSettings.playbackForwardSecondsKey)
        UserDefaults.standard.set(15.0, forKey: AppSettings.playbackBackwardSecondsKey)
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(previousValues[key], forKey: key) }
        super.tearDown()
    }

    func testPreviousTrackGoesBackInBothModes() {
        var calls: [String] = []
        let session = PlaybackSystemSession(actions: .init(
            play: {}, pause: {}, toggle: {}, next: { calls.append("next") },
            previous: { calls.append("previous") }, seek: { _ in }, skip: { calls.append("skip \(Int($0))") },
            setRate: { _ in }, interruption: { _, _ in }, routeChange: { _ in }, mediaServicesReset: {}))
        UserDefaults.standard.set(RemoteButtonMode.skip.rawValue, forKey: RemoteButtonMode.storageKey)
        session.handleTrackCommand(forward: false)
        session.handleTrackCommand(forward: true)
        UserDefaults.standard.set(RemoteButtonMode.chapter.rawValue, forKey: RemoteButtonMode.storageKey)
        session.handleTrackCommand(forward: false)
        session.handleTrackCommand(forward: true)
        XCTAssertEqual(calls, ["skip -15", "skip 30", "previous", "next"])
    }

    func testEveryRemoteTrackCommandAnnouncesANarrationJumpSoTheReaderFollowsAgain() throws {
        let suite = "remote-jumps-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var jumps = 0
        let subscription = player.narrationJumps.sink { jumps += 1 }
        defer { subscription.cancel() }
        for mode in RemoteButtonMode.allCases {
            UserDefaults.standard.set(mode.rawValue, forKey: RemoteButtonMode.storageKey)
            player.services.system.handleTrackCommand(forward: true)
            player.services.system.handleTrackCommand(forward: false)
        }
        XCTAssertEqual(jumps, 4)
    }
}
