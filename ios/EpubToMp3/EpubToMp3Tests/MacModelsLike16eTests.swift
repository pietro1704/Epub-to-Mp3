#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// MAC-MODELS-BY-LANGUAGE: the iPhone 16e is the base. Its Models root shows the narration options as
/// switches with their description under the title, in the order automatic system voice, online voices,
/// footnotes, low-quality voices, then a "Languages" row with a globe and a disclosure chevron; every
/// language in the language list opens with a chevron too. The Mac mirrors that content and order.
@MainActor
final class MacModelsLike16eTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func visible(_ view: NSView, identifier: String) -> NSView? {
        descendants(view).first { $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func label(_ view: NSView, text: String) -> NSTextField? {
        descendants(view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == text && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).maxY }

    func testRootShowsTheNarrationSwitchesWithDescriptionsAndALanguagesRowLikeThe16e() async throws {
        let name = "mac-models-like-16e-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = MacModelsViewController(settings: AppSettings(defaults: defaults),
                                                 source: ModelsByLanguageModelTests.FakeSource(),
                                                 termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults),
                                                 bookLanguages: { [] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        for _ in 0..<60 { try await Task.sleep(nanoseconds: 50_000_000) }
        controller.view.layoutSubtreeIfNeeded()

        let options = [("settings.tts.automaticSystemFallback", "settings.automaticSystemFallbackDescription"),
                       ("settings.tts.onlineConsent", "settings.onlineFallbackDescription"),
                       ("settings.tts.footnoteNarration", "settings.footnoteNarrationDescription"),
                       ("models.showLowQuality", "models.showLowQualityDescription")]
        var tops: [CGFloat] = []
        for (identifier, descriptionKey) in options {
            let control = try XCTUnwrap(visible(controller.view, identifier: identifier), identifier)
            XCTAssertTrue(control is NSSwitch, "\(identifier) is a switch, as on the 16e")
            XCTAssertNotNil(label(controller.view, text: L10n.string(descriptionKey)),
                            "\(identifier) shows its description under the title, as on the 16e")
            tops.append(top(control))
        }
        let languages = try XCTUnwrap(visible(controller.view, identifier: "models.languages") as? NSButton)
        XCTAssertFalse(languages.isBordered, "Languages is a row with a chevron, not a push button")
        XCTAssertNotNil(label(controller.view, text: L10n.string("models.languages.open")))
        tops.append(top(languages))
        XCTAssertEqual(tops, tops.sorted(by: >), "Narration options then Languages, top to bottom, as on the 16e")
        attachCapture(of: window, name: "mac-models-root-like-16e")
    }

    func testLanguageListRowsOpenWithADisclosureChevron() throws {
        let controller = MacModelsLanguagesViewController(
            languages: [CatalogLanguage(tag: "pt", modelCount: 3), CatalogLanguage(tag: "en", modelCount: 5)],
            systemPreferred: ["pt-BR"], uiLocale: Locale(identifier: "en"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()

        for tag in ["pt", "en"] {
            XCTAssertNotNil(visible(controller.view, identifier: "models.languages.row.\(tag)"))
            let chevron = visible(controller.view, identifier: "models.languages.chevron.\(tag)") as? NSImageView
            XCTAssertNotNil(chevron?.image, "The \(tag) row shows a disclosure chevron, as on the 16e")
        }
        attachCapture(of: window, name: "mac-models-languages-like-16e")
    }

    private func attachCapture(of window: NSWindow, name: String) {
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
