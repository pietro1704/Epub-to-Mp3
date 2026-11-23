import XCTest
@testable import EpubToMp3

@MainActor
final class LanguageModelPlaybackTests: XCTestCase {
    private let book = BookEntity(id: "book", title: "Book", bookmark: Data([1]), displayFilename: "book.epub", addedAt: Date())
    private let faber = TtsSelection(engine: "piper", modelID: "pt_BR-faber-medium", voice: nil)
    private let cadu = TtsSelection(engine: "piper", modelID: "pt_BR-cadu-medium", voice: nil)

    private func makeSettings() throws -> (AppSettings, UserDefaults, String) {
        let name = "language-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(faber)
        return (settings, defaults, name)
    }

    private final class Calls { var language = 0; var resolve = 0; var installed = 0 }

    private func dependencies(language: String?, status: LanguageModelResolution.Status = .selected,
                              selection: TtsSelection? = nil, calls: Calls = Calls(),
                              failing: Bool = false) -> LanguageModelPlayback.Dependencies {
        .init(bookLanguage: { _ in calls.language += 1; return language },
              resolve: { request in
                  calls.resolve += 1
                  if failing { throw EmbeddedConverterError.artifactUnavailable }
                  return LanguageModelResolution(bookLanguage: request.bookLanguage, status: status, selection: selection,
                                                 source: .perLanguage, reasons: [], missing: nil)
              },
              installedModelIDs: { calls.installed += 1; return ["pt_BR-faber-medium", "pt_BR-cadu-medium"] },
              systemVoiceLanguages: { ["pt-BR"] })
    }

    func testWithoutAnyLanguageChoiceTheResultIsExactlyTodaysAndNothingIsAnalyzed() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let calls = Calls()
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: "pt-BR", calls: calls))
        XCTAssertEqual(outcome, .useSettings, "Primary Piper Faber for pt, as before")
        XCTAssertEqual(calls.language + calls.resolve + calls.installed, 0, "No book analysis, no resolver, no catalog read")
        XCTAssertEqual(settings.ttsPreferences.primary, faber)
    }

    func testAChoiceForAnotherLanguageLeavesThisBookUntouched() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil), for: "en")
        let calls = Calls()
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: "pt-BR", calls: calls))
        XCTAssertEqual(outcome, .useSettings)
        XCTAssertEqual(calls.resolve, 0)
    }

    func testAnExplicitPerJobSelectionSkipsTheResolver() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(cadu, for: "pt")
        let calls = Calls()
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: true,
                                                          dependencies: dependencies(language: "pt-BR", selection: cadu, calls: calls))
        XCTAssertEqual(outcome, .useSettings)
        XCTAssertEqual(calls.language + calls.resolve, 0, "A manual override stays authoritative")
    }

    func testAnUnconfirmedLanguageKeepsTheCurrentFlow() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(cadu, for: "pt")
        let calls = Calls()
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: nil, calls: calls))
        XCTAssertEqual(outcome, .useSettings)
        XCTAssertEqual(calls.resolve, 0)
    }

    func testTheLanguageChoiceBecomesThePrimaryAndTheRestOfTheSettingsIsKept() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(cadu, for: "pt")
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: "pt-BR", selection: cadu))
        guard case let .use(preferences) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(preferences.primary, cadu)
        XCTAssertEqual(preferences.secondary, settings.ttsPreferences.secondary)
        XCTAssertEqual(preferences.allowOnlineFallback, settings.ttsPreferences.allowOnlineFallback)
        XCTAssertEqual(preferences.policyVersion, settings.ttsPreferences.policyVersion)
        XCTAssertEqual(settings.primaryTtsSelection, faber, "Resolving never rewrites the saved primary")
    }

    func testAChoiceEqualToThePrimaryChangesNothing() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(faber, for: "pt")
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: "pt", selection: faber))
        XCTAssertEqual(outcome, .useSettings)
    }

    func testAReserveEqualToTheResolvedPrimaryIsDropped() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectSecondaryNarration(.systemDefault)
        settings.selectLanguageModel(.systemDefault, for: "pt")
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: "pt", status: .systemFallback, selection: .systemDefault))
        guard case let .use(preferences) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(preferences.primary, .systemDefault)
        XCTAssertNil(preferences.secondary, "The reserve must differ from the primary")
    }

    func testAMissingModelIsReportedForTheAlertAndNeverDownloaded() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(cadu, for: "pt")
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: "pt-BR", status: .missingModel))
        XCTAssertEqual(outcome, .missing(language: "pt-BR"))
        // The existing recovery alert understands the error that stands for it.
        let mismatch = TtsLanguageMismatch.decode(LanguageModelPlayback.missingModelError(language: "pt-BR"))
        XCTAssertEqual(mismatch?.language, "pt-BR")
    }

    func testAResolverFailureFallsBackToTodaysBehavior() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(cadu, for: "pt")
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
                                                          dependencies: dependencies(language: "pt", failing: true))
        XCTAssertEqual(outcome, .useSettings)
    }
}
