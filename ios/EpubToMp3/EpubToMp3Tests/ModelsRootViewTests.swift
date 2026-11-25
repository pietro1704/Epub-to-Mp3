import XCTest
@testable import EpubToMp3
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// A2 (step 3): the root of Models draws "the voice for each language" and opens the language page.
@MainActor
final class ModelsRootViewTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "models-root-view-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testTheLibraryLanguagesSurviveARestartAndFollowCorrectionsAndRemoval() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrections = BookLanguageCorrections(defaults: defaults)
        BookLanguageSummaries(defaults: defaults).record("fr", bookID: "a")
        BookLanguageSummaries(defaults: defaults).record("de", bookID: "b")
        BookLanguageSummaries(defaults: defaults).record(nil, bookID: "c")
        try corrections.set("es", bookID: "b")
        XCTAssertEqual(BookLanguageSummaries(defaults: defaults).languages(corrections: corrections), ["fr", "es"])
        BookLanguageSummaries(defaults: defaults).remove(bookID: "a")
        XCTAssertEqual(BookLanguageSummaries(defaults: defaults).languages(corrections: corrections), ["es"])
    }

    func testARootItemNamesTheResolvedVoiceAndPutsTheFocusedLanguageFirst() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ModelsByLanguageModel(source: ModelsByLanguageModelTests.FakeSource(),
                                          settings: AppSettings(defaults: defaults),
                                          terms: SpeechModelTermsAcceptanceStore(defaults: defaults),
                                          systemVoiceLanguages: { [] })
        await model.load()
        let items = model.rootItems(systemLanguages: ["pt-BR"], bookLanguages: ["fr"], priority: "fr",
                                    uiLocale: Locale(identifier: "en")) { _ in nil }
        XCTAssertEqual(items.map(\.language), ["fr", "pt"])
        XCTAssertEqual(items.map(\.title), ["French", "Portuguese"])
        XCTAssertFalse(items[0].needsVoice, "Not resolved yet is not a missing voice")
    }

    private func makeLoadedDefaults() throws -> (AppSettings, UserDefaults, String) {
        let (defaults, suite) = try makeDefaults()
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }

#if os(iOS)
    func testTheRootListsALanguageRowPerLanguageAndOpensItsPage() async throws {
        let (settings, defaults, suite) = try makeLoadedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ModelsScreenController(settings: settings, source: ModelsByLanguageModelTests.FakeSource(),
            termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults), focusLanguage: "fr",
            bookLanguages: { ["fr"] })
        let navigation = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertEqual(controller.numberOfSections(in: table), 2)
        try await waitUntil { controller.tableView(table, numberOfRowsInSection: 1) > 0 }
        let first = IndexPath(row: 0, section: 1)
        XCTAssertEqual(controller.tableView(table, cellForRowAt: first).accessibilityIdentifier, "models.language.fr")
        XCTAssertEqual(controller.tableView(table, cellForRowAt: first).accessoryType, .disclosureIndicator)
        UIView.performWithoutAnimation { controller.tableView(table, didSelectRowAt: first) }
        try await waitUntil { navigation.viewControllers.count == 2 }
    }
#else
    func testTheRootListsALanguageRowPerLanguageAndNoVoiceModels() async throws {
        let (settings, defaults, suite) = try makeLoadedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MacModelsViewController(settings: settings, source: ModelsByLanguageModelTests.FakeSource(),
            termsAcceptance: SpeechModelTermsAcceptanceStore(defaults: defaults), focusLanguage: "fr",
            bookLanguages: { ["fr"] })
        controller.view.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        func identifiers() -> [String] {
            (0..<table.numberOfRows).compactMap {
                table.view(atColumn: 0, row: $0, makeIfNecessary: true)?.accessibilityIdentifier()
            }.filter { !$0.isEmpty }
        }
        try await waitUntil { identifiers().first == "models.language.fr" }
        XCTAssertFalse(identifiers().contains { $0.hasPrefix("models.row.") })
        controller.view.layoutSubtreeIfNeeded()
        if let rep = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) {
            controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
            if let directory = ProcessInfo.processInfo.environment["EPUB_EVIDENCE_DIR"],
               let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("models-root.png"))
            }
        }
    }
#endif
}
