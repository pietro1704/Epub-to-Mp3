import XCTest
@testable import EpubToMp3

/// A2 (step 2): the model hands the root of Models its rows, with the inputs Rust needs to resolve each language.
@MainActor
final class ModelsRootModelTests: XCTestCase {
    private let faber = TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)

    private func makeModel() async throws -> (ModelsByLanguageModel, AppSettings, UserDefaults, String) {
        let suite = "models-root-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(faber)
        let model = ModelsByLanguageModel(source: ModelsByLanguageModelTests.FakeSource(), settings: settings,
                                          terms: SpeechModelTermsAcceptanceStore(),
                                          systemVoiceLanguages: { ["pt", "en"] })
        await model.load()
        return (model, settings, defaults, suite)
    }

    func testTheRootListsEachLanguageOnceAndAsksRustWithWhatIsInstalledAndChosen() async throws {
        let (model, settings, defaults, suite) = try await makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.selectLanguageModel(TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil), for: "pt")
        var requests: [LanguageModelResolutionRequest] = []
        let rows = model.rootRows(systemLanguages: ["pt-BR", "en-US"], bookLanguages: ["fr"]) { request in
            requests.append(request)
            return nil
        }
        XCTAssertEqual(rows.map(\.language), ["pt", "en", "fr"])
        let portuguese = try XCTUnwrap(requests.first { SpeechPreferences.languageKey($0.bookLanguage) == "pt" })
        XCTAssertEqual(portuguese.installedModelIDs, ["pt_BR-faber-medium"], "Only what is installed is offered")
        XCTAssertEqual(portuguese.perLanguageChoices["pt"]?.modelID, "pt_BR-cadu-medium")
        XCTAssertEqual(portuguese.primary, faber)
        XCTAssertEqual(portuguese.systemVoices.sorted(), ["en", "pt"])
        XCTAssertEqual(portuguese.platform, LanguageModelResolutionRequest.currentPlatform)
    }

    func testALanguageWithAnInstalledVoiceIsListedEvenWhenNoSystemLanguageOrBookNeedsIt() async throws {
        let (model, _, defaults, suite) = try await makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = model.rootRows(systemLanguages: [], bookLanguages: []) { _ in nil }
        XCTAssertEqual(rows.map(\.language), ["pt"], "Faber is installed")
        XCTAssertTrue(rows[0].reasons.contains(.installed))
    }
}
