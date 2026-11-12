#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class BackendSettingsRowsTests: XCTestCase {
    func testAbsentWarningDoesNotReserveAnEmptyLastRow() {
        XCTAssertEqual(SettingsSection.backend.rowCount(speechModels: .empty), 1)
        XCTAssertEqual(SettingsSection.backend.rowCount(speechModels: .empty,
            backendWarningVisible: true), 2)
        XCTAssertEqual(SettingsSection.backend.rowCount(speechModels: .empty,
            backendWarningVisible: false), 1)
    }

    func testDisabledRemoteBackendHasOneVisibleURLCellEvenWithInvalidURL() throws {
        let suite = "BackendRows.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.backendURL = "invalid"
        XCTAssertFalse(RuntimeSettingsRows.backendWarningVisible(settings: settings))
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.register(IOSInlineTextFieldCell.self, forCellReuseIdentifier: "TextField")
        let cell = RuntimeSettingsRows.backendCell(for: IndexPath(row: 0, section: 1),
            tableView: table, settings: settings, controller: UIViewController())
        XCTAssertFalse(cell.isHidden)
        let field = try XCTUnwrap(cell as? IOSInlineTextFieldCell)
        XCTAssertFalse(field.textField.isEnabled)
        XCTAssertEqual(field.textField.text, "invalid")
    }
}
#endif
