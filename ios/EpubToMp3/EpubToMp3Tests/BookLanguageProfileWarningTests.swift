import XCTest
@testable import EpubToMp3

/// BOOK-LANGUAGE-PROFILE on the client (CONTEXT.md, "Book language profile"): decode the profile and warn, before
/// playing and without blocking, about the profile's languages that have no voice.
@MainActor
final class BookLanguageProfileWarningTests: XCTestCase {
    /// The real result for "O Jardim das Aflições": monolingual pt-BR, quotations in other languages are incidental.
    private let jardimJSON = """
    {"confirmed":"pt-BR","declared":"en","detector":"whatlang-0.18/book-consensus-v1","inconclusive_samples":0,
     "languages":["pt-BR"],"samples_examined":5,"schema_version":1,
     "profile":{"class":"monolingual","detector":"whatlang-0.18/book-profile-v1",
       "incidental":["fr-FR","es-ES","en","it-IT","la","ca"],
       "languages":[{"chars":828868,"fraction":0.9799382150461614,"language":"pt-BR","longest_section_chars":137303}],
       "primary":"pt-BR","total_chars":871789,"undetermined_chars":25952,"version":1}}
    """
    private let bilingualJSON = """
    {"confirmed":"pt-BR","declared":"pt","detector":"d","inconclusive_samples":0,"languages":["pt-BR","fr-FR"],
     "samples_examined":5,"schema_version":1,
     "profile":{"class":"bilingual","detector":"d","incidental":[],
       "languages":[{"chars":600,"fraction":0.6,"language":"pt-BR","longest_section_chars":300},
                    {"chars":400,"fraction":0.4,"language":"fr-FR","longest_section_chars":200}],
       "primary":"pt-BR","total_chars":1000,"undetermined_chars":0,"version":1}}
    """
    private let book = BookEntity(id: "book", title: "Book", bookmark: Data([1]), displayFilename: "book.epub", addedAt: Date())

    func testTheRealJardimProfileDecodesAsMonolingualWithIncidentalQuotations() throws {
        let analysis = try JSONDecoder().decode(BookLanguageAnalysis.self, from: Data(jardimJSON.utf8))
        let profile = try XCTUnwrap(analysis.profile)
        XCTAssertEqual(profile.kind, .monolingual)
        XCTAssertEqual(profile.primary, "pt-BR")
        XCTAssertEqual(profile.languages.map(\.language), ["pt-BR"])
        XCTAssertEqual(profile.incidental, ["fr-FR", "es-ES", "en", "it-IT", "la", "ca"])
        XCTAssertEqual(try XCTUnwrap(profile.languages.first).fraction, 0.98, accuracy: 0.001)
    }

    func testAnOlderLibraryWithoutAProfileStillDecodes() throws {
        let legacy = #"{"confirmed":"en","declared":"en","languages":["en"],"samples_examined":5,"inconclusive_samples":0}"#
        let analysis = try JSONDecoder().decode(BookLanguageAnalysis.self, from: Data(legacy.utf8))
        XCTAssertNil(analysis.profile)
        XCTAssertEqual(analysis.confirmed, "en")
    }

    private func dependencies(profile languages: [String], missing: Set<String>, failing: Bool = false)
        -> LanguageModelPlayback.Dependencies {
        .init(bookLanguage: { _ in "pt-BR" },
              resolve: { request in
                  if failing { throw EmbeddedConverterError.artifactUnavailable }
                  let isMissing = missing.contains(SpeechPreferences.languageKey(request.bookLanguage))
                  return LanguageModelResolution(bookLanguage: request.bookLanguage, status: isMissing ? .missingModel : .selected,
                                                 selection: isMissing ? nil : .systemDefault, source: .perLanguage,
                                                 reasons: [], missing: nil)
              },
              installedModelIDs: { [] }, systemVoiceLanguages: { [] }, profileLanguages: { _ in languages })
    }

    private func settings() throws -> (AppSettings, UserDefaults, String) {
        let name = "profile-warning-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (AppSettings(defaults: defaults), defaults, name)
    }

    func testAMonolingualBookWarnsAboutNothing() async throws {
        let (settings, defaults, name) = try settings(); defer { defaults.removePersistentDomain(forName: name) }
        let missing = await LanguageModelPlayback.missingProfileLanguages(
            for: book, settings: settings, dependencies: dependencies(profile: ["pt-BR"], missing: ["fr"]))
        XCTAssertEqual(missing, [], "Only the profile's languages count; a French quotation is not one")
    }

    func testABilingualBookNamesTheLanguageWithoutAVoiceAndNeverTheMainOne() async throws {
        let (settings, defaults, name) = try settings(); defer { defaults.removePersistentDomain(forName: name) }
        let missing = await LanguageModelPlayback.missingProfileLanguages(
            for: book, settings: settings, dependencies: dependencies(profile: ["pt-BR", "fr-FR"], missing: ["fr", "pt"]))
        XCTAssertEqual(missing, ["fr"], "pt is the main language: its own missing-model flow handles it, not this warning")
    }

    func testALanguageWithAVoiceIsNotMentionedAndTheListHasNoDuplicates() async throws {
        let (settings, defaults, name) = try settings(); defer { defaults.removePersistentDomain(forName: name) }
        let missing = await LanguageModelPlayback.missingProfileLanguages(
            for: book, settings: settings,
            dependencies: dependencies(profile: ["pt-BR", "fr-FR", "fr-CA", "de", "it"], missing: ["fr", "it"]))
        XCTAssertEqual(missing, ["fr", "it"])
    }

    func testAFailingResolverNeverBlocksOrWarns() async throws {
        let (settings, defaults, name) = try settings(); defer { defaults.removePersistentDomain(forName: name) }
        let missing = await LanguageModelPlayback.missingProfileLanguages(
            for: book, settings: settings, dependencies: dependencies(profile: ["pt-BR", "fr"], missing: ["fr"], failing: true))
        XCTAssertEqual(missing, [])
    }

    func testTheNoticeNamesEachLanguageInTheUILanguage() {
        let english = PlatformFallbackNotice.message(forMissingLanguages: ["fr", "it"], locale: Locale(identifier: "en"))
        XCTAssertTrue(english.contains("French") && english.contains("Italian"), english)
        let portuguese = PlatformFallbackNotice.message(forMissingLanguages: ["fr"], locale: Locale(identifier: "pt-BR"))
        XCTAssertTrue(portuguese.contains("francês"), portuguese)
    }

    func testTheNoticeNamesTheLanguagesInEveryLocale() {
        for localization in ["en", "pt-BR", "es"] {
            let bundle = L10n.localizationBundle(localization)
            XCTAssertNotEqual(L10n.string("conversion.profileMissingVoices", "X", bundle: bundle), "conversion.profileMissingVoices",
                              "missing in \(localization)")
        }
    }
}
