import XCTest
@testable import EpubToMp3
#if os(iOS)
import UIKit
#endif

@MainActor
final class ConversionSettingsAccessibilityTests: XCTestCase {
    func testReaderSettingsRefreshNotifiesPresenterAndRetainsAccessibleControls() throws {
#if os(iOS)
        let suite = "reader-settings-accessibility-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ReaderSettingsScreenController(settings: AppSettings(defaults: defaults))
        controller.loadViewIfNeeded()
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(controller.tableView.accessibilityLabel, L10n.string("readerSettings.title"))
        XCTAssertEqual(controller.tableView.rowHeight, UITableView.automaticDimension)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItem?.title, L10n.string("readerSettings.done"))
        XCTAssertNotNil(controller.navigationItem.rightBarButtonItem?.action)
#else
        throw XCTSkip("UIKit accessibility requires the iOS runtime; Simulator execution remains quarantined.")
#endif
    }
    func testReaderSettingsChoicesExposeCurrentLabelsValuesAndHints() throws {
#if os(iOS)
        let suite = "settings-choice-hints-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        let rows = ReaderSettingsRows(tableView: table, settings: settings)
        let choice = rows.cell(for: IndexPath(row: 1, section: 0))
        XCTAssertEqual(choice.accessibilityLabel, L10n.string("settings.font"))
        XCTAssertEqual(choice.accessibilityValue, settings.readerFontFamily.displayName)
        XCTAssertEqual(choice.accessibilityHint, L10n.string("settings.openOptionHint"))
        let toggle = rows.cell(for: IndexPath(row: 6, section: 0))
        XCTAssertEqual(toggle.accessibilityHint, L10n.string("settings.autoScrollHint"))
        XCTAssertNil(toggle.accessibilityValue, "Reused cells must not announce a stale selection value.")
#else
        throw XCTSkip("UIKit accessibility requires iOS; Simulator execution remains quarantined.")
#endif
    }

}
