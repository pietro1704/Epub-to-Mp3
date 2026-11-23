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

    func testChoiceSheetsHaveExactlyOneCancelWhenPresented() throws {
        let (controller, defaults, name) = try makeController()
        defer { defaults.removePersistentDomain(forName: name) }
        let source = IndexPath(row: 0, section: 0)
        for alert in [controller.primaryChoicesAlert(), controller.secondaryChoicesAlert()] {
            let before = alert.actions.count
            XCTAssertGreaterThanOrEqual(before, 1)
            // This is the call that threw NSInternalInconsistencyException before the fix.
            SettingsAlertPresentation.actionSheet(alert, on: controller, tableView: controller.tableView, source: source)
            XCTAssertEqual(cancelCount(alert), 1)
            XCTAssertEqual(alert.actions.count, before + 1, "Exactly the one shared cancel is appended")
        }
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
