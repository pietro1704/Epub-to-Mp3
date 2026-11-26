#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// SINGLE-CHOICE-POP: a screen that picks exactly one thing returns as soon as the choice is made.
@MainActor
final class ReaderFontChoiceControllerTests: XCTestCase {
    func testChoosingAFontReturnsToThePreviousScreen() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var selections = 0
        let previous = UIViewController()
        let navigation = UINavigationController(rootViewController: previous)
        let picker = ReaderFontChoiceController(settings: AppSettings(defaults: defaults)) { selections += 1 }
        navigation.pushViewController(picker, animated: false)
        picker.loadViewIfNeeded()
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(selections, 1)
        XCTAssertTrue(navigation.topViewController === previous, "the picker must close after the choice")
    }
}
#endif
