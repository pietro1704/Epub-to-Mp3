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
        XCTAssertEqual(SettingsSection.playback.rowCount(speechModels: .empty), 3)

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
