#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// Temporary capture for the pull request; never merged.
@MainActor
final class BookScopeCaptureTests: XCTestCase {
    func testCaptureBookScopeSwitch() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let prefix = "bookprefs-\(UUID().uuidString)"
        let books = BookReadingPreferencesStore(registry: defaults, suiteNamePrefix: prefix)
        defer { books.remove("book-a"); defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enterBookScope("book-a", store: books)
        settings.useBookScopeByDefault(store: books)
        let screen = ReaderSettingsScreenController(settings: settings)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            window.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "book-scope-on-by-default"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
