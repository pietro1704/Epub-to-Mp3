import XCTest
@testable import EpubToMp3

/// MODELS-LANGUAGE-SUBSCREEN: the Models screen lists only the relevant languages; the rest live on the language screen.
final class ModelsRelevantLanguagesTests: XCTestCase {
    private func row(_ id: String, system: Bool = false, ready: Bool, chosen: Bool = false) -> ModelsByLanguageViewState.Row {
        .init(id: id, kind: .local, title: id, detail: "medium",
              selection: system ? .systemDefault : .defaultPiper,
              availability: ready ? .ready : .downloadable(bytes: 1), isChosen: chosen)
    }

    private func state() -> ModelsByLanguageViewState {
        ModelsByLanguageViewState(sections: [
            .init(language: "de", rows: [row("de-system", system: true, ready: true), row("de-piper", ready: false)]),
            .init(language: "en", rows: [row("en-system", system: true, ready: true), row("en-piper", ready: true)]),
            .init(language: "es", rows: [row("es-piper", ready: false), row("es-chosen", ready: false, chosen: true)]),
            .init(language: "pt", rows: [row("pt-system", system: true, ready: true), row("pt-piper", ready: false)]),
        ])
    }

    func testListsTheFocusLanguageTheChosenAndTheInstalledOnesInTheirOrder() {
        let sections = state().relevantSections(priority: "pt-BR", systemPreferred: ["de-DE"])
        XCTAssertEqual(sections.map(\.language), ["en", "es", "pt"],
                       "en has a downloaded model, es a saved choice, pt is the book's; de only has a system voice")
    }

    func testTheAlwaysAvailableSystemVoiceDoesNotMakeALanguageRelevant() {
        let only = ModelsByLanguageViewState(sections: [
            .init(language: "de", rows: [row("de-system", system: true, ready: true), row("de-piper", ready: false)]),
        ])
        XCTAssertEqual(only.relevantSections(priority: nil, systemPreferred: []).map(\.language), [],
                       "No system language to fall back to")
        XCTAssertEqual(only.relevantSections(priority: nil, systemPreferred: ["de-AT"]).map(\.language), ["de"],
                       "Falls back to the first system language that has models")
    }

    func testFallsBackToTheFirstSystemLanguageWhenNothingIsRelevant() {
        let none = ModelsByLanguageViewState(sections: [
            .init(language: "de", rows: [row("de-piper", ready: false)]),
            .init(language: "pt", rows: [row("pt-piper", ready: false)]),
        ])
        XCTAssertEqual(none.relevantSections(priority: nil, systemPreferred: ["xx", "pt-BR", "de"]).map(\.language), ["pt"])
    }

    func testASingleLanguageSectionIsFoundByAnyTagOfThatLanguage() {
        XCTAssertEqual(state().section(for: "pt-BR")?.language, "pt")
        XCTAssertNil(state().section(for: "xx"))
    }
}
