#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// The narration controls the old voice-models detail carried now live on the Models screen with
/// the same accessibility identifiers: default voice, reserve voice, system-voice fallback and the
/// online consent. (Ports the removed popup tests; AppKit no longer lists choices it would disable.)
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
        let primary = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "settings.tts.primary" })
        let secondary = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "settings.tts.secondary" })
        let online = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.tts.onlineConsent" })
        let automatic = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "settings.tts.automaticSystemFallback" })
        XCTAssertEqual(primary.accessibilityLabel(), L10n.string("settings.audioEngineChoice"))
        XCTAssertEqual(secondary.accessibilityLabel(), L10n.string("settings.secondaryVoice"))
        XCTAssertEqual(primary.titleOfSelectedItem, settings.primaryTtsSelection.modelID, "The saved default voice is shown")
        XCTAssertEqual(online.state, .off)
        XCTAssertFalse(secondary.itemTitles.contains("Edge"), "Online voices are not offered as the reserve without consent")

        // The default voice persists through the control.
        primary.selectItem(withTitle: L10n.string("settings.systemTts"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(primary.action), to: primary.target, from: primary))
        XCTAssertEqual(AppSettings(defaults: defaults).primaryTtsSelection, .systemDefault)
        // The reserve cannot repeat the default voice.
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(secondary.itemTitles.contains(L10n.string("settings.systemTts")), "The reserve differs from the default voice")

        // With the consent on, Edge becomes a possible reserve and persists.
        online.performClick(nil)
        XCTAssertTrue(AppSettings(defaults: defaults).allowOnlineAudioFallback)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(secondary.itemTitles.contains("Edge"))
        secondary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertEqual(AppSettings(defaults: defaults).secondaryTtsSelection?.engine, "edge")
        // Withdrawing the consent drops the online reserve (existing policy) and the screen follows.
        online.performClick(nil)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(AppSettings(defaults: defaults).secondaryTtsSelection)
        XCTAssertEqual(secondary.titleOfSelectedItem, L10n.string("settings.noSecondary"))

        // The system-voice fallback setting persists.
        automatic.performClick(nil)
        XCTAssertFalse(AppSettings(defaults: defaults).allowAutomaticSystemVoiceFallback)
    }
}
#endif
