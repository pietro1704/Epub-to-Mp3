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

    func testNarrationMenusListTheEnginesFirstAndPiperHoldsItsModels() throws {
        let (controller, defaults, name) = try makeController()
        defer { defaults.removePersistentDomain(forName: name) }
        let primary = controller.narrationMenu(secondary: false)
        XCTAssertEqual(primary.children.map(\.title), [L10n.string("models.engine.system"), "Piper", "Edge"])
        let piper = try XCTUnwrap(primary.children[1] as? UIMenu)
        XCTAssertFalse(piper.children.isEmpty, "Piper opens a list of its voices")
        XCTAssertTrue(primary.children[0] is UIAction, "System selects directly")
        let secondary = controller.narrationMenu(secondary: true)
        XCTAssertEqual(secondary.children.map(\.title).first, L10n.string("settings.noSecondary"))
        XCTAssertEqual(secondary.children.count, 4)
    }

    /// The menu button must cover the whole narration row once laid out (a zero-sized overlay would make the row untappable).
    func testNarrationRowButtonCoversTheWholeRowAfterLayout() throws {
        let (controller, defaults, name) = try makeController()
        defer { defaults.removePersistentDomain(forName: name) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.tableView.reloadData()
        controller.tableView.layoutIfNeeded()
        for row in [0, 1] {  // primary, secondary narration rows
            let cell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: row, section: 0)))
            let button = try XCTUnwrap(cell.contentView.viewWithTag(4242) as? UIButton, "menu button missing")
            cell.layoutIfNeeded()
            XCTAssertGreaterThan(button.bounds.width, 100, "button must span the row (row \(row))")
            XCTAssertEqual(button.bounds.width, cell.contentView.bounds.width, accuracy: 0.5, "button must match the content width (row \(row))")
            XCTAssertEqual(button.bounds.height, cell.contentView.bounds.height, accuracy: 0.5, "button must match the content height (row \(row))")
        }
    }

    /// Each narration row's button must open ITS menu (primary: System/Piper/Edge; secondary: None first), also after
    /// the rows are reloaded and the cells are reused (a tap on the primary row once opened the secondary menu).
    func testEachNarrationRowButtonOpensItsOwnMenuAfterReloads() throws {
        let (controller, defaults, name) = try makeController()
        defer { defaults.removePersistentDomain(forName: name) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.tableView.layoutIfNeeded()
        for round in 0..<3 {
            controller.tableView.reloadRows(at: [IndexPath(row: 0, section: 0), IndexPath(row: 1, section: 0)], with: .none)
            controller.tableView.layoutIfNeeded()
            for (row, identifier, firstTitle) in [(0, "settings.tts.primary", L10n.string("models.engine.system")),
                                                  (1, "settings.tts.secondary", L10n.string("settings.noSecondary"))] {
                let cell = try XCTUnwrap(controller.tableView.cellForRow(at: IndexPath(row: row, section: 0)))
                let buttons = cell.contentView.subviews.compactMap { $0 as? UIButton }
                XCTAssertEqual(buttons.count, 1, "exactly one menu button per row (round \(round), row \(row))")
                let button = try XCTUnwrap(buttons.first)
                XCTAssertEqual(button.accessibilityIdentifier, identifier, "round \(round)")
                XCTAssertEqual(button.menu?.children.first?.title, firstTitle, "wrong menu behind \(identifier) (round \(round))")
            }
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
