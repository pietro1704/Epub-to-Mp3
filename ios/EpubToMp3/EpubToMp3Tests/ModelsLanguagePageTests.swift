import XCTest
#if os(iOS)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

/// A2 (design 2026-11-24): the language page lists its voices by engine, System first, then Piper, then Edge.
final class ModelsLanguagePageTests: XCTestCase {
    private func row(_ id: String, _ selection: TtsSelection,
                     kind: ModelsByLanguageViewState.Kind = .local) -> ModelsByLanguageViewState.Row {
        .init(id: id, kind: kind, title: id, detail: "medium", selection: selection, availability: .ready, isChosen: false)
    }

    private var piperA: ModelsByLanguageViewState.Row {
        row("piper:a", TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil))
    }
    private var piperB: ModelsByLanguageViewState.Row {
        row("piper:b", TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil))
    }

    func testTheLanguagePageListsSystemThenPiperThenEdgeAndKeepsTheOrderInsideAnEngine() {
        let section = ModelsByLanguageViewState.Section(language: "pt", rows: [
            piperA, row("system:pt", .systemDefault), piperB, row("edge:pt", .edgeDefault, kind: .online),
        ])
        XCTAssertEqual(section.engineSections.map(\.engine), [.system, .piper, .edge])
        XCTAssertEqual(section.engineSections.map { $0.rows.map(\.id) }, [["system:pt"], ["piper:a", "piper:b"], ["edge:pt"]])
    }

    func testAnEngineWithoutVoicesHasNoSection() {
        let section = ModelsByLanguageViewState.Section(language: "pt", rows: [piperA])
        XCTAssertEqual(section.engineSections.map(\.engine), [.piper])
    }

    /// The loaded Portuguese page over a suite of its own, with a system voice installed for the language.
    @MainActor
    private func loadedModel() async throws -> (model: ModelsByLanguageModel, settings: AppSettings) {
        let name = "models-language-page-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        let model = ModelsByLanguageModel(source: ModelsByLanguageModelTests.FakeSource(), settings: settings,
                                          terms: SpeechModelTermsAcceptanceStore(defaults: defaults),
                                          systemVoiceLanguages: { ["pt-BR"] })
        await model.load()
        settings.selectLanguageModel(.systemDefault, for: "pt")
        return (model, settings)
    }

#if os(iOS)
    @MainActor
    func testTheLanguagePageStartsWithAutomaticAndThenListsTheEngines() async throws {
        let (model, settings) = try await loadedModel()
        let controller = ModelsScreenController(sharing: model, settings: settings, onlyLanguage: "pt")
        controller.loadViewIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        let table = try XCTUnwrap(controller.tableView)
        XCTAssertEqual(table.numberOfSections, 4)
        XCTAssertEqual((1..<4).map { controller.tableView(table, titleForHeaderInSection: $0) },
                       [L10n.string("models.engine.system"), L10n.string("models.page.piper"), L10n.string("models.page.edge")])
        let automatic = IndexPath(row: 0, section: 0)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
        let chosenVoice = controller.tableView(table, cellForRowAt: automatic)
        XCTAssertEqual(chosenVoice.accessibilityIdentifier, "models.automatic.pt")
        XCTAssertEqual(chosenVoice.accessoryType, .none, "A voice is chosen")

        controller.tableView(table, didSelectRowAt: automatic)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(settings.languageModelChoices["pt"])
        XCTAssertEqual(controller.tableView(table, cellForRowAt: automatic).accessoryType, .checkmark)
    }
#else
    @MainActor
    func testTheLanguagePageStartsWithAutomaticAndThenListsTheEngines() async throws {
        let (model, settings) = try await loadedModel()
        let controller = MacModelsViewController(sharing: model, onlyLanguage: "pt")
        controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 640)
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
        func texts(_ row: Int) -> [String] {
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return [] }
            return descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
        }
        XCTAssertEqual(texts(0).first, L10n.string("models.page.automatic"), "A voice is chosen: no check mark")
        let headers = (0..<table.numberOfRows).filter { controller.tableView(table, isGroupRow: $0) }
            .compactMap { texts($0).first }
        XCTAssertEqual(headers, [L10n.string("models.engine.system"), L10n.string("models.page.piper"),
                                 L10n.string("models.page.edge")])

        controller.activateRow(at: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(settings.languageModelChoices["pt"])
        XCTAssertEqual(texts(0).first, "✓ " + L10n.string("models.page.automatic"))
    }
#endif
}
