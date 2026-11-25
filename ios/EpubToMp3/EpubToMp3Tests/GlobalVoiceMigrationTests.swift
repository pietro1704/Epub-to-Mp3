import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// The global voice menus are gone: what they saved moves to per-language choices, once.
final class GlobalVoiceMigrationTests: XCTestCase {
    private var suites: [String] = []
    private let englishPiper = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil)

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    /// A store written by a build that still had the global menus.
    private func seeded(primary: TtsSelection, secondary: TtsSelection? = nil,
                        choices: [String: TtsSelection] = [:], consent: Bool = false) throws -> UserDefaults {
        let suite = "global-voice-migration-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(1, forKey: SpeechPreferenceMigration.versionKey)
        defaults.set(try JSONEncoder().encode(primary), forKey: SpeechPreferenceMigration.Key.primarySelection)
        if let secondary {
            defaults.set(try JSONEncoder().encode(secondary), forKey: SpeechPreferenceMigration.Key.secondarySelection)
        }
        defaults.set(try JSONEncoder().encode(choices), forKey: SpeechPreferences.languageModelChoicesKey)
        defaults.set(consent, forKey: SpeechPreferenceMigration.Key.onlineFallbackConsent)
        return defaults
    }

    private func load(_ defaults: UserDefaults) -> SpeechPreferences {
        SpeechPreferences(defaults: defaults, preferredLanguages: ["pt-BR", "en-US"])
    }

    func testOtherPiperPrimaryBecomesTheChoiceOfItsLanguage() throws {
        let defaults = try seeded(primary: englishPiper, secondary: .systemDefault)
        let preferences = load(defaults)
        XCTAssertEqual(preferences.languageModelChoices, ["en": englishPiper])
        XCTAssertEqual(preferences.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(preferences.secondaryTtsSelection, .systemDefault)
        XCTAssertEqual(load(defaults).languageModelChoices, ["en": englishPiper], "The result is saved.")
    }

    func testAnExistingLanguageChoiceWins() throws {
        let amy = TtsSelection(engine: "piper", modelID: "en_US-amy-medium", voice: nil)
        let preferences = load(try seeded(primary: englishPiper, choices: ["en": amy]))
        XCTAssertEqual(preferences.languageModelChoices, ["en": amy])
        XCTAssertEqual(preferences.primaryTtsSelection, .defaultPiper)
    }

    func testDefaultPiperPrimaryIsUntouched() throws {
        let preferences = load(try seeded(primary: .defaultPiper, secondary: .systemDefault))
        XCTAssertEqual(preferences.languageModelChoices, [:])
        XCTAssertEqual(preferences.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(preferences.secondaryTtsSelection, .systemDefault)
    }

    func testSystemPrimaryIsCopiedToDeviceAndLibraryLanguages() throws {
        let defaults = try seeded(primary: .systemDefault, choices: ["en": englishPiper])
        BookLanguageSummaries(defaults: defaults).record("es-ES", bookID: "spanish")
        let preferences = load(defaults)
        XCTAssertEqual(preferences.languageModelChoices,
                       ["pt": .systemDefault, "es": .systemDefault, "en": englishPiper])
        XCTAssertEqual(preferences.primaryTtsSelection, .defaultPiper)
    }

    func testConsentedEdgePrimaryIsCopied() throws {
        let preferences = load(try seeded(primary: .edgeDefault, consent: true))
        XCTAssertEqual(preferences.languageModelChoices, ["pt": .edgeDefault, "en": .edgeDefault])
        XCTAssertEqual(preferences.primaryTtsSelection, .defaultPiper)
    }

    /// A reserve equal to the new primary would be dropped; the old primary takes its place.
    func testReserveEqualToTheNewPrimarySwapsWithTheOldPrimary() throws {
        let preferences = load(try seeded(primary: .systemDefault, secondary: .defaultPiper))
        XCTAssertEqual(preferences.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(preferences.secondaryTtsSelection, .systemDefault)
    }

    /// A store that never ran either migration goes through both on one load.
    func testLegacyEngineStoreRunsBothMigrations() throws {
        let suite = "global-voice-migration-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("system", forKey: SpeechPreferenceMigration.Key.legacyPrimaryEngine)
        defaults.set("piper", forKey: SpeechPreferenceMigration.Key.legacySecondaryEngine)
        let preferences = load(defaults)
        XCTAssertEqual(preferences.languageModelChoices, ["pt": .systemDefault, "en": .systemDefault])
        XCTAssertEqual(preferences.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(preferences.secondaryTtsSelection, .systemDefault)
    }

    func testMigrationRunsOnce() throws {
        let defaults = try seeded(primary: .defaultPiper)
        load(defaults).selectPrimaryNarration(.systemDefault)
        let reloaded = load(defaults)
        XCTAssertEqual(reloaded.primaryTtsSelection, .systemDefault)
        XCTAssertEqual(reloaded.languageModelChoices, [:])
    }
}
