#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacTtsMissingVoiceAlertTests: XCTestCase {
    func testButtonsMatchTheIOSAlertAndDisabledChoicesAreNotOffered() {
        XCTAssertEqual(MacTtsMissingVoiceAlert.actions(hasRecommended: true, systemAvailable: true),
                       [.recommended, .models, .system, .cancel])
        XCTAssertEqual(MacTtsMissingVoiceAlert.actions(hasRecommended: false, systemAvailable: false), [.models, .cancel])
        XCTAssertEqual(MacTtsMissingVoiceAlert.actions(hasRecommended: false, systemAvailable: true), [.models, .system, .cancel])
    }

    func testTheAlertUsesTheSameLocalizedTextAsIOSAndLeadsToTheModelsScreen() {
        let alert = MacTtsMissingVoiceAlert.makeAlert(language: "pt-BR", recommended: nil, systemAvailable: true)
        XCTAssertEqual(alert.messageText, L10n.string("tts.missingVoice.title"))
        XCTAssertNotEqual(alert.messageText, "tts.missingVoice.title", "The key must exist in every locale")
        let language = Locale.current.localizedString(forIdentifier: "pt-BR") ?? "pt-BR"
        XCTAssertEqual(alert.informativeText, L10n.string("tts.missingVoice.message", language))
        XCTAssertEqual(alert.buttons.map(\.title), [L10n.string("tts.missingVoice.openSettings"),
                                                     L10n.string("tts.missingVoice.system"), L10n.string("common.cancel")])
        XCTAssertEqual(alert.window.accessibilityIdentifier(), "tts.missingVoice.alert")
    }
}
#endif
