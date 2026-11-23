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
        let primaryVoice = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "settings.tts.primary.voice" })
        XCTAssertEqual(primary.accessibilityLabel(), L10n.string("settings.audioEngineChoice"))
        XCTAssertEqual(secondary.accessibilityLabel(), L10n.string("settings.secondaryVoice"))
        // Engine first: System, Piper, Edge; the voice sits inside the engine (second popup).
        XCTAssertEqual(primary.itemTitles, [L10n.string("models.engine.system"), "Piper", "Edge"])
        XCTAssertEqual(primary.titleOfSelectedItem, "Piper", "The saved default (Faber) is shown as its engine")
        XCTAssertFalse(primaryVoice.isHidden)
        XCTAssertTrue(primaryVoice.itemTitles.contains { $0.contains("faber") || $0.contains("Faber") })
        XCTAssertEqual(secondary.itemTitles.first, L10n.string("settings.noSecondary"))
        XCTAssertEqual(online.state, .off)
        XCTAssertEqual(primary.item(withTitle: "Edge")?.isEnabled, false, "Edge needs the online permission")

        // Choosing the System engine applies at once and hides the voice list.
        primary.selectItem(withTitle: L10n.string("models.engine.system"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(primary.action), to: primary.target, from: primary))
        XCTAssertEqual(AppSettings(defaults: defaults).primaryTtsSelection, .systemDefault)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(primaryVoice.isHidden)
        XCTAssertEqual(secondary.item(withTitle: L10n.string("models.engine.system"))?.isEnabled, false,
                       "The reserve cannot repeat the default engine")

        // With the consent on, Edge becomes possible; withdrawing it drops the online reserve.
        online.performClick(nil)
        XCTAssertTrue(AppSettings(defaults: defaults).allowOnlineAudioFallback)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(secondary.item(withTitle: "Edge")?.isEnabled, true)
        secondary.selectItem(withTitle: "Edge")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(secondary.action), to: secondary.target, from: secondary))
        XCTAssertEqual(AppSettings(defaults: defaults).secondaryTtsSelection?.engine, "edge")
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
