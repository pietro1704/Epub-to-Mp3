#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

/// Temporary capture for the pull request; never merged.
@MainActor
final class ModelsRootCaptureTests: XCTestCase {
    func testCaptureModelsRootWhileLoading() async throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = ModelsByLanguageModelTests.GatedSource()
        let screen = ModelsScreenController(settings: AppSettings(defaults: defaults), source: source,
                                            termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults),
                                            focusLanguage: "pt", bookLanguages: { ["pt"] })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func capture(_ title: String) async throws {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = title
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try await capture("models-root-loading")
        source.release()
        try await capture("models-root-loaded")
    }
}
#endif
