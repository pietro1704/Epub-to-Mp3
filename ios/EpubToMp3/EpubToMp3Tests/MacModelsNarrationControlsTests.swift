#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// The Models screen keeps the system-voice fallback and the online consent under their accessibility
/// identifiers. The voice itself is chosen per language and per book, so there is no global voice popup.
@MainActor
final class MacModelsNarrationControlsTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testNarrationControlsPersistChoicesAndRespectTheOnlineConsent() async throws {
        let name = "mac-models-narration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let controller = MacModelsViewController(settings: settings, source: ModelsByLanguageModelTests.FakeSource(),
                                                 termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        for _ in 0..<60 { try await Task.sleep(nanoseconds: 50_000_000) }
        let controls = descendants(controller.view)
        XCTAssertTrue(controls.compactMap { $0 as? NSPopUpButton }.isEmpty, "No global voice or reserve popup")
        let online = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.tts.onlineConsent" })
        let automatic = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.tts.automaticSystemFallback" })
        XCTAssertEqual(online.state, .off)

        // Withdrawing the consent drops a saved online reserve.
        online.performClick(nil)
        XCTAssertTrue(AppSettings(defaults: defaults).allowOnlineAudioFallback)
        settings.selectSecondaryNarration(.edgeDefault)
        online.performClick(nil)
        XCTAssertNil(AppSettings(defaults: defaults).secondaryTtsSelection)

        // The system-voice fallback setting persists.
        automatic.performClick(nil)
        XCTAssertFalse(AppSettings(defaults: defaults).allowAutomaticSystemVoiceFallback)

        // FOOTNOTE-NARRATION: on by default; turning it off is saved and sent to Rust as `skip`.
        let footnotes = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.tts.footnoteNarration" })
        XCTAssertEqual(footnotes.state, .on)
        footnotes.performClick(nil)
        XCTAssertFalse(AppSettings(defaults: defaults).narratesFootnotes)
        XCTAssertEqual(AppSettings(defaults: defaults).ttsPreferences.footnoteNarration, .skip)
    }
}
#endif
