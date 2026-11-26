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
        let previous = ReaderSettingsScreenController(settings: AppSettings(defaults: defaults))
        let navigation = UINavigationController(rootViewController: previous)
        let picker = ReaderFontChoiceController(settings: AppSettings(defaults: defaults)) { selections += 1 }
        navigation.pushViewController(picker, animated: false)
        picker.loadViewIfNeeded()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func capture(_ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                window.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("font-picker-open")
        picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        capture("font-picker-after-choice")
        XCTAssertEqual(selections, 1)
        XCTAssertTrue(navigation.topViewController === previous, "the picker must close after the choice")
    }
}
#endif
