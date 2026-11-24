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

    func testABookCompatibleWithThePrimaryKeepsTodaysResultWithoutAnyChoice() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let calls = Calls()
        // Rust answers "the saved primary" for pt with Faber installed.
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
            dependencies: dependencies(language: "pt-BR", selection: faber, calls: calls))
        XCTAssertEqual(outcome, .useSettings, "Primary Piper Faber for pt, exactly as before")
        XCTAssertEqual(calls.language, 1, "The language is analyzed (and cached per book by the live dependency)")
        XCTAssertEqual(calls.resolve, 1)
        XCTAssertEqual(settings.ttsPreferences.primary, faber)
    }

    func testADifferentLanguageWithoutAChoiceUsesTheBestInstalledModelOfThatLanguage() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let english = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil)
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
            dependencies: dependencies(language: "en", selection: english))
        guard case let .use(preferences) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(preferences.primary, english, "An English book never keeps the Portuguese primary")
        XCTAssertEqual(settings.primaryTtsSelection, faber, "The saved primary is not rewritten")
    }

    func testADifferentLanguageWithoutAModelFallsToTheSystemVoiceThenToTheMissingModelAlert() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let system = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
            dependencies: dependencies(language: "en", status: .systemFallback, selection: .systemDefault))
        guard case let .use(preferences) = system else { return XCTFail("\(system)") }
        XCTAssertEqual(preferences.primary, .systemDefault)
        let missing = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
            dependencies: dependencies(language: "en", status: .missingModel))
        XCTAssertEqual(missing, .missing(language: "en"))
    }

    func testAChoiceForAnotherLanguageDoesNotChangeThisBook() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.selectLanguageModel(TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil), for: "en")
        let outcome = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
            dependencies: dependencies(language: "pt-BR", selection: faber))
        XCTAssertEqual(outcome, .useSettings)
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

    // MARK: the real Rust resolver

    private func bundledAdapter() throws -> ConverterFFIAdapter {
        let library = try XCTUnwrap(Bundle.main.privateFrameworksURL).appendingPathComponent("libconverter_ffi.dylib")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "No embedded Rust library")
        return ConverterFFIAdapter(libraryURL: library)
    }

    private func realDependencies(_ adapter: ConverterFFIAdapter, language: String, installed: [String],
                                  systemVoices: [String] = []) -> LanguageModelPlayback.Dependencies {
        .init(bookLanguage: { _ in language }, resolve: { try adapter.resolveLanguageModel($0) },
              installedModelIDs: { installed }, systemVoiceLanguages: { systemVoices })
    }

    func testRealResolverKeepsTodaysResultForPortugueseWithFaberAndNeverKeepsItForEnglish() async throws {
        let adapter = try bundledAdapter()
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let go = { (language: String, installed: [String], voices: [String]) async -> LanguageModelPlayback.Outcome in
            await LanguageModelPlayback.outcome(for: self.book, settings: settings, hasExplicitSelection: false,
                dependencies: self.realDependencies(adapter, language: language, installed: installed, systemVoices: voices))
        }
        // pt + Faber installed: exactly today's (the saved primary).
        let portuguese = await go("pt-BR", ["pt_BR-faber-medium"], [])
        XCTAssertEqual(portuguese, .useSettings)
        // English, nothing English installed, no system voice: the alert.
        let none = await go("en", ["pt_BR-faber-medium"], [])
        XCTAssertEqual(none, .missing(language: "en"))
        // English, system voice installed (setting on by default): the system voice.
        guard case let .use(system) = await go("en", ["pt_BR-faber-medium"], ["en-US"]) else { return XCTFail() }
        XCTAssertEqual(system.primary, .systemDefault)
        // English model installed: it wins before the system voice.
        guard case let .use(english) = await go("en", ["pt_BR-faber-medium", "en_US-ljspeech-high"], ["en-US"]) else { return XCTFail() }
        XCTAssertEqual(english.primary.modelID, "en_US-ljspeech-high")
        XCTAssertEqual(settings.primaryTtsSelection, faber)
        // With the system-voice fallback turned off the alert comes back.
        settings.allowAutomaticSystemVoiceFallback = false
        let off = await go("en", ["pt_BR-faber-medium"], ["en-US"])
        XCTAssertEqual(off, .missing(language: "en"))
    }

    // MARK: background (offline chapter) conversions

    func testOfflineChapterOptionsFollowTheLanguageResolution() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let english = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil)
        let used = try await LanguageModelPlayback.conversionOptions(
            for: book, settings: settings, dependencies: dependencies(language: "en", selection: english))
        XCTAssertEqual(used.ttsPreferences?.primary.modelID, "en_US-ljspeech-high", "An English book is narrated in English")
        let same = try await LanguageModelPlayback.conversionOptions(
            for: book, settings: settings, dependencies: dependencies(language: "pt", selection: faber))
        XCTAssertEqual(same.ttsPreferences?.primary.modelID, "pt_BR-faber-medium", "pt with Faber: exactly today's options")
        XCTAssertEqual(same.ttsPreferences, NarrationConversionOptions.current(for: settings.ttsPreferences).ttsPreferences)
        do {
            _ = try await LanguageModelPlayback.conversionOptions(
                for: book, settings: settings, dependencies: dependencies(language: "en", status: .missingModel))
            XCTFail("Nothing can read the language: no silent conversion with the wrong model")
        } catch {
            XCTAssertEqual(TtsLanguageMismatch.decode(error)?.language, "en")
        }
    }

    // MARK: Primary language of the book (HOTFIX A0)

    private func analysis(languages: [String], confirmed: String? = "fr-FR", declared: String? = "pt",
                          primary: String? = "pt-BR") throws -> BookLanguageAnalysis {
        let profile = primary.map { """
            ,"profile":{"class":"monolingual","primary":"\($0)","languages":[],"incidental":["fr-FR"]}
            """ } ?? ""
        let json = """
            {"declared":\(declared.map { "\"\($0)\"" } ?? "null"),"confirmed":\(confirmed.map { "\"\($0)\"" } ?? "null"),
             "languages":[\(languages.map { "\"\($0)\"" }.joined(separator: ","))],
             "samples_examined":32,"inconclusive_samples":0\(profile)}
            """
        return try JSONDecoder().decode(BookLanguageAnalysis.self, from: Data(json.utf8))
    }

    private final class Requests { var resolved: [LanguageModelResolutionRequest] = [] }

    private func analysisDependencies(_ analysis: BookLanguageAnalysis, correction: String? = nil,
                                      requests: Requests) -> LanguageModelPlayback.Dependencies {
        var dependencies = LanguageModelPlayback.Dependencies(
            bookLanguage: { _ in analysis.languages.first },
            resolve: { request in
                requests.resolved.append(request)
                return LanguageModelResolution(bookLanguage: request.bookLanguage, status: .selected, selection: self.faber,
                                               source: .perLanguage, reasons: [], missing: nil)
            },
            installedModelIDs: { ["pt_BR-faber-medium"] }, systemVoiceLanguages: { ["pt-BR"] })
        dependencies.bookAnalysis = { _ in analysis }
        dependencies.userLanguage = { _ in correction }
        return dependencies
    }

    func testAPortugueseBookWithAFrenchQuotationResolvesTheModelOfThePrimaryLanguage() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let requests = Requests()
        // `languages` is an alphabetical set of the sampled languages: fr-FR sorts before pt-BR.
        let analysis = try analysis(languages: ["fr-FR", "pt-BR"], confirmed: "fr-FR", primary: "pt-BR")
        _ = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
            dependencies: analysisDependencies(analysis, requests: requests))
        XCTAssertEqual(requests.resolved.map(\.bookLanguage), ["pt-BR"],
                       "The resolver gets the profile's primary language, not the first sampled one")
    }

    func testABookTheUserCorrectedResolvesTheCorrectedLanguage() async throws {
        let (settings, defaults, name) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        let requests = Requests()
        let analysis = try analysis(languages: ["fr-FR", "pt-BR"], primary: "pt-BR")
        _ = await LanguageModelPlayback.outcome(for: book, settings: settings, hasExplicitSelection: false,
            dependencies: analysisDependencies(analysis, correction: "en-US", requests: requests))
        XCTAssertEqual(requests.resolved.map(\.bookLanguage), ["en-US"], "The user's correction reaches the model resolver")
    }

    func testTheLanguageRuleIsCorrectionThenProfilePrimaryThenConfirmedNeverTheFirstSampleOrTheDeclaredTag() throws {
        let both = try analysis(languages: ["fr-FR", "pt-BR"], confirmed: "es-ES", primary: "pt-BR")
        XCTAssertEqual(both.resolvedLanguage(userCorrection: "en-US"), "en-US")
        XCTAssertEqual(both.resolvedLanguage(userCorrection: nil), "pt-BR")
        XCTAssertEqual(both.resolvedLanguage(userCorrection: ""), "pt-BR", "An empty correction is no correction")
        let older = try analysis(languages: ["fr-FR", "pt-BR"], confirmed: "es-ES", primary: nil)
        XCTAssertEqual(older.resolvedLanguage(userCorrection: nil), "es-ES", "An older library without a profile keeps the confirmed language")
        let unknown = try analysis(languages: ["fr-FR"], confirmed: nil, declared: "pt", primary: nil)
        XCTAssertNil(unknown.resolvedLanguage(userCorrection: nil), "Neither languages.first nor the declared tag decides")
    }
}
