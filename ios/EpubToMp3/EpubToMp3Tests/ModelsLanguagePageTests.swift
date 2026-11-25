import XCTest
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
}
