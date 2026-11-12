#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class PlatformSettingsCellTests: XCTestCase {
    func testReusingAnInformationCellReleasesItsPreviousSwitch() {
        let cell = IOSContentCell(style: .default, reuseIdentifier: "Cell")
        cell.accessoryView = UISwitch()
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityTraits = .adjustable
        weak var previousSwitch = cell.accessoryView
        cell.prepareForReuse()
        XCTAssertNil(cell.accessoryView)
        XCTAssertNil(previousSwitch)
        XCTAssertEqual(cell.accessoryType, .none)
        XCTAssertFalse(cell.accessibilityTraits.contains(.adjustable))
    }

    func testPlatformRowIsReadOnlyInformation() throws {
        let suite = "PlatformRow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.register(IOSContentCell.self, forCellReuseIdentifier: "Cell")
        let presentation = SettingsCellPresentation(tableView: table, settings: AppSettings(defaults: defaults),
            storageUsage: StorageUsageScanner.current(), diagnosticsSession: StreamingDiagnosticsSession(clock: { 0 }))
        let row = presentation.aboutCell(for: IndexPath(row: 1, section: 6))
        XCTAssertNil(row.accessoryView)
        XCTAssertEqual(row.accessoryType, .none)
        XCTAssertEqual(row.selectionStyle, .none)
        XCTAssertEqual(row.accessibilityIdentifier, "settings.platform")
        XCTAssertTrue(row.accessibilityTraits.contains(.staticText))
        let content = try XCTUnwrap(row.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.text, L10n.string("settings.platform"))
        XCTAssertFalse(try XCTUnwrap(content.secondaryText).isEmpty)
    }
}
#endif
