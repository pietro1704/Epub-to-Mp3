#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// P0 regression: tapping the default voice on the Models screen crashed the app (UIKit throws when an alert
/// has two cancel actions; the sheet and `SettingsAlertPresentation.actionSheet` each added one).
@MainActor
final class ModelsScreenAlertTests: XCTestCase {
    private func makeController() throws -> (ModelsScreenController, UserDefaults, String) {
        let name = "models-alert-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let controller = ModelsScreenController(settings: AppSettings(defaults: defaults),
                                                source: ModelsByLanguageModelTests.FakeSource(),
                                                termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults))
        controller.loadViewIfNeeded()
        return (controller, defaults, name)
    }

    private func cancelCount(_ alert: UIAlertController) -> Int { alert.actions.filter { $0.style == .cancel }.count }

    /// The voice is chosen per language and per book: the root keeps no global voice control.
    func testRootHasNoGlobalVoiceControls() throws {
        let (controller, defaults, name) = try makeController()
        defer { defaults.removePersistentDomain(forName: name) }
        let table: UITableView = controller.tableView
        let rows = (0..<controller.tableView(table, numberOfRowsInSection: 0)).map {
            controller.tableView(table, cellForRowAt: IndexPath(row: $0, section: 0))
        }
        XCTAssertEqual(rows.compactMap(\.accessibilityIdentifier), ["models.languages"])
        XCTAssertEqual(rows.count, 5, "Two fallback switches, the footnote switch, the quality filter and the language list")
        XCTAssertFalse(rows.flatMap { $0.contentView.subviews }.contains { ($0 as? UIButton)?.menu != nil })
        XCTAssertNil(controller.tableView(table, titleForHeaderInSection: 0))
        XCTAssertNil(controller.tableView(table, titleForFooterInSection: 0))
    }

    func testActionSheetNeverAddsASecondCancel() throws {
        let (controller, defaults, name) = try makeController()
        defer { defaults.removePersistentDomain(forName: name) }
        let alert = UIAlertController(title: "t", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "one", style: .default))
        alert.addAction(UIAlertAction(title: "own cancel", style: .cancel))
        SettingsAlertPresentation.actionSheet(alert, on: controller, tableView: controller.tableView,
                                              source: IndexPath(row: 0, section: 0))
        XCTAssertEqual(cancelCount(alert), 1)
        XCTAssertEqual(alert.actions.count, 2)
    }
}
#endif
