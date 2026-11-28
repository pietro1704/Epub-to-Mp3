import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import EpubToMp3

/// SILENCE-TRIM-LEVELS: the level is a Settings default that a manual conversion can
/// override; Rust trims the audio, so Apple only has to send `silence_trim`.
@MainActor
final class SilenceTrimSettingTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "SilenceTrim.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    private func sentLevel(_ preferences: TtsPreferences?) throws -> String? {
        let data = try JSONEncoder().encode(try XCTUnwrap(preferences))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["silence_trim"] as? String
    }

    func testSavedLevelReachesTheConversionPreferences() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(try sentLevel(AppSettings(defaults: defaults).ttsPreferences))
        for level in ["off", "medium", "strong"] {
            defaults.set(level, forKey: "silenceTrim")
            XCTAssertEqual(try sentLevel(AppSettings(defaults: defaults).ttsPreferences), level)
        }
        // `light` is the Rust default: leaving it out keeps existing cache identities.
        defaults.set("light", forKey: "silenceTrim")
        XCTAssertNil(try sentLevel(AppSettings(defaults: defaults).ttsPreferences))
    }

    func testDecodingAndCatalogCaptureKeepTheLevel() throws {
        let json = #"{"primary":{"engine":"piper"},"allow_online_fallback":false,"silence_trim":"strong"}"#
        let preferences = try JSONDecoder().decode(TtsPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(try sentLevel(preferences), "strong")
        let captured = try ConverterFFIAdapter().ttsCatalog()
            .capture(preferences, target: NarrationConversionOptions.platformTarget)
        XCTAssertEqual(try sentLevel(captured), "strong")
    }

#if os(macOS)
    private func descendant<View: NSView>(_ type: View.Type, _ identifier: String, in root: NSView) -> View? {
        if let match = root as? View, match.accessibilityIdentifier() == identifier { return match }
        return root.subviews.lazy.compactMap { self.descendant(type, identifier, in: $0) }.first
    }

    private func choose(_ index: Int, in popup: NSPopUpButton) {
        popup.selectItem(at: index)
        _ = popup.sendAction(popup.action, to: popup.target)
    }

    private var levelTitles: [String] {
        ["off", "light", "medium", "strong"].map { L10n.string("silenceTrim.level.\($0)") }
    }

    func testMacSettingsChooseTheDefaultLevel() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let controller = MacModelsViewController(settings: settings, source: ModelsByLanguageModelTests.FakeSource(),
            termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults), bookLanguages: { [] })
        controller.view.layoutSubtreeIfNeeded()
        let popup = try XCTUnwrap(descendant(NSPopUpButton.self, "settings.tts.silenceTrim", in: controller.view))
        XCTAssertEqual(popup.itemTitles, levelTitles)
        choose(3, in: popup)
        XCTAssertEqual(try sentLevel(settings.ttsPreferences), "strong")
        XCTAssertEqual(try sentLevel(AppSettings(defaults: defaults).ttsPreferences), "strong")
    }

    func testMacManualConversionStartsAtTheDefaultAndCanOverrideIt() async throws {
        let (defaults, suite) = try makeDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silence-trim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("synthetic.txt")
        try Data("Synthetic fixture.".utf8).write(to: source)
        defaults.set("medium", forKey: "silenceTrim")
        let settings = AppSettings(defaults: defaults)
        var sent: [TtsPreferences?] = []
        let model = ConvertViewModel(session: ManualConversionSession(executor: { _, _, _, _, options, _, _ in
            sent.append(options?.ttsPreferences)
            throw CancellationError()
        }))
        let controller = MacConvertScreenController(settings: settings,
            library: LibraryStore(defaults: defaults, importDirectory: root.appendingPathComponent("library")),
            viewModel: model, inboxDirectory: root.appendingPathComponent("inbox"))
        controller.view.layoutSubtreeIfNeeded()
        await controller.selectDocument(source)
        let popup = try XCTUnwrap(descendant(NSPopUpButton.self, "convert.silenceTrim", in: controller.view))
        XCTAssertEqual(popup.itemTitles, levelTitles)
        XCTAssertEqual(popup.indexOfSelectedItem, 2)
        await controller.submit()
        // With the saved voice preferences.
        choose(0, in: popup)
        await controller.submit()
        // With an explicit engine for this conversion only.
        choose(1, in: controller.form.engine)
        await controller.submit()
        XCTAssertEqual(try sent.map { try sentLevel($0) }, ["medium", "off", "off"])
        // `light` must override a non-default setting too.
        choose(1, in: popup)
        await controller.submit()
        XCTAssertNil(try sentLevel(try XCTUnwrap(sent.last)))
        XCTAssertEqual(try sentLevel(settings.ttsPreferences), "medium", "The override never changes Settings.")
    }
#else
    func testIOSSettingsAndManualConversionShowTheLevelControl() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("medium", forKey: "silenceTrim")
        let settings = AppSettings(defaults: defaults)
        let screen = ModelsScreenController(settings: settings, source: ModelsByLanguageModelTests.FakeSource(),
            termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults), bookLanguages: { [] })
        let player = AudioPlayer()
        let convert = ConvertScreenController(settings: settings,
            library: LibraryStore(defaults: defaults), player: player, playbackClock: PlaybackClock())
        for (controller, identifier) in [(screen as UITableViewController, "settings.tts.silenceTrim"),
                                         (convert, "convert.silenceTrim")] {
            controller.loadViewIfNeeded()
            let table: UITableView = try XCTUnwrap(controller.tableView)
            let cells = (0..<controller.numberOfSections(in: table)).flatMap { section in
                (0..<controller.tableView(table, numberOfRowsInSection: section)).map {
                    controller.tableView(table, cellForRowAt: IndexPath(row: $0, section: section))
                }
            }
            let cell = try XCTUnwrap(cells.first { $0.accessibilityIdentifier == identifier }, identifier)
            XCTAssertEqual(cell.accessibilityValue, L10n.string("silenceTrim.level.medium"))
        }
    }
#endif
}
