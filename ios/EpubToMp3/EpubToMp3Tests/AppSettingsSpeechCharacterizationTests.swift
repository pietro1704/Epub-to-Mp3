import Combine
import XCTest
@testable import EpubToMp3

/// Pins the speech surface of `AppSettings` (defaults, explicit selections,
/// the secondary and online-consent rules, persisted keys and values, change
/// publication, and the interplay with `SpeechPreferenceMigration`) so the
/// speech preferences can move behind `AppSettings` without changing it.
final class AppSettingsSpeechCharacterizationTests: XCTestCase {
    private typealias Key = SpeechPreferenceMigration.Key
    private var suites: [String] = []
    private let englishPiper = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil)

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "speech-characterization-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func saved(_ defaults: UserDefaults, _ key: String) -> TtsSelection? {
        SpeechPreferenceMigration.decodeSelection(defaults, key: key)
    }

    private func changeCount(of settings: AppSettings, during mutate: () -> Void) -> Int {
        var changes = 0
        let observation = settings.objectWillChange.sink { changes += 1 }
        mutate()
        withExtendedLifetime(observation) {}
        return changes
    }

    // MARK: Defaults

    func testFreshStoreDefaultsAndTheKeysTheyLeaveOnDisk() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper)
        XCTAssertEqual(settings.secondaryTtsSelection, .systemDefault)
        XCTAssertFalse(settings.allowOnlineAudioFallback)
        XCTAssertTrue(settings.allowAutomaticSystemVoiceFallback)
        XCTAssertEqual(settings.primaryEngine, "piper")
        XCTAssertEqual(settings.ttsPreferences, TtsPreferences(primary: .defaultPiper, secondary: .systemDefault,
                                                               allowOnlineFallback: false, policyVersion: 2))
        XCTAssertEqual(settings.configuredNarrationSelections, [.defaultPiper, .systemDefault])
        XCTAssertEqual(settings.selectableSecondaryEngines, ["system"])

        XCTAssertEqual(saved(defaults, Key.primarySelection), .defaultPiper)
        XCTAssertEqual(saved(defaults, Key.secondarySelection), .systemDefault)
        XCTAssertEqual(defaults.integer(forKey: SpeechPreferenceMigration.versionKey), SpeechPreferenceMigration.currentVersion)
        XCTAssertNil(defaults.object(forKey: Key.onlineFallbackConsent), "Loading must not write the consent default")
        XCTAssertNil(defaults.object(forKey: "allowAutomaticSystemVoiceFallback"),
                     "Loading must not write the automatic-fallback default")
    }

    func testSelectionsArePersistedAsTtsSelectionJSON() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(englishPiper)

        let data = try XCTUnwrap(defaults.data(forKey: Key.primarySelection))
        XCTAssertEqual(try JSONDecoder().decode(TtsSelection.self, from: data), englishPiper)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["engine"] as? String, "piper")
        XCTAssertEqual(json["model_id"] as? String, "en_US-ljspeech-high")
    }

    // MARK: Explicit selections and the secondary rule

    func testPrimaryChangeClearsOnlyARepeatedSecondaryAndPersistsEveryWrite() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.selectPrimaryNarration(englishPiper)
        XCTAssertEqual(settings.secondaryTtsSelection, .systemDefault)
        XCTAssertEqual(saved(defaults, Key.primarySelection), englishPiper)

        settings.selectPrimaryNarration(.systemDefault)
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection), "A cleared secondary removes its key")
        XCTAssertEqual(AppSettings(defaults: defaults).primaryTtsSelection, .systemDefault)
        XCTAssertNil(AppSettings(defaults: defaults).secondaryTtsSelection, "An explicit none survives relaunch")
    }

    func testRejectedSecondaryLeavesNoSecondaryEvenWhenOneWasSaved() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.secondaryTtsSelection, .systemDefault)

        settings.selectSecondaryNarration(.defaultPiper)
        XCTAssertNil(settings.secondaryTtsSelection, "Repeating the primary is rejected")
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))

        settings.selectSecondaryNarration(englishPiper)
        XCTAssertEqual(saved(defaults, Key.secondarySelection), englishPiper, "Another Piper model is a different request")
        settings.selectSecondaryNarration(.edgeDefault)
        XCTAssertNil(settings.secondaryTtsSelection, "Edge without consent is rejected")
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))
    }

    // MARK: Online consent

    func testConsentEnablesEdgeAndRevokingItClearsOnlyAnEdgeSecondary() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.allowOnlineAudioFallback = true
        XCTAssertEqual(defaults.object(forKey: Key.onlineFallbackConsent) as? Bool, true)
        XCTAssertEqual(settings.selectableSecondaryEngines, ["system", "edge"])
        settings.selectSecondaryNarration(.edgeDefault)
        XCTAssertEqual(settings.ttsPreferences.secondary, .edgeDefault)
        XCTAssertTrue(settings.ttsPreferences.allowOnlineFallback)

        settings.allowOnlineAudioFallback = false
        XCTAssertEqual(defaults.object(forKey: Key.onlineFallbackConsent) as? Bool, false)
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))

        settings.selectSecondaryNarration(.systemDefault)
        settings.allowOnlineAudioFallback = true
        settings.allowOnlineAudioFallback = false
        XCTAssertEqual(settings.secondaryTtsSelection, .systemDefault, "Revocation keeps a non-Edge secondary")
    }

    func testEdgePrimaryIsAllowedWithoutConsentAndHidesNoSecondaryEngine() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.selectPrimaryNarration(.edgeDefault)

        XCTAssertEqual(settings.primaryEngine, "edge")
        XCTAssertEqual(settings.selectableSecondaryEngines, ["piper", "system"])
        XCTAssertEqual(settings.ttsPreferences.primary, .edgeDefault)
        XCTAssertFalse(settings.ttsPreferences.allowOnlineFallback)
    }

    func testSavedUnconsentedEdgeSecondaryIsExposedButNeverSent() throws {
        let defaults = try makeDefaults()
        SpeechPreferenceMigration.runIfNeeded(defaults)
        defaults.set(try JSONEncoder().encode(TtsSelection.edgeDefault), forKey: Key.secondarySelection)

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.secondaryTtsSelection, .edgeDefault)
        XCTAssertNil(settings.ttsPreferences.secondary)
        XCTAssertEqual(settings.configuredNarrationSelections, [.defaultPiper])
        XCTAssertEqual(saved(defaults, Key.secondarySelection), .edgeDefault, "Loading does not rewrite it")
    }

    // MARK: Automatic system fallback

    func testAutomaticSystemFallbackMapsToThePolicyVersionAndPersists() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)

        settings.allowAutomaticSystemVoiceFallback = false
        XCTAssertEqual(defaults.object(forKey: "allowAutomaticSystemVoiceFallback") as? Bool, false)
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 3)
        XCTAssertFalse(AppSettings(defaults: defaults).allowAutomaticSystemVoiceFallback)

        settings.allowAutomaticSystemVoiceFallback = true
        XCTAssertEqual(defaults.object(forKey: "allowAutomaticSystemVoiceFallback") as? Bool, true)
        XCTAssertEqual(settings.ttsPreferences.policyVersion, 2)
    }

    // MARK: Change publication

    func testEverySpeechMutationPublishesAChange() throws {
        let settings = AppSettings(defaults: try makeDefaults())
        XCTAssertEqual(changeCount(of: settings) { settings.selectPrimaryNarration(englishPiper) }, 1)
        XCTAssertEqual(changeCount(of: settings) { settings.selectSecondaryNarration(nil) }, 1)
        XCTAssertEqual(changeCount(of: settings) { settings.allowAutomaticSystemVoiceFallback = false }, 1)
        XCTAssertEqual(changeCount(of: settings) { settings.allowOnlineAudioFallback = true }, 1)
        settings.selectSecondaryNarration(.edgeDefault)
        XCTAssertEqual(changeCount(of: settings) { settings.allowOnlineAudioFallback = false }, 2,
                       "Revoking consent publishes the consent and the cleared Edge secondary")
        settings.selectSecondaryNarration(.defaultPiper)
        XCTAssertEqual(changeCount(of: settings) { settings.selectPrimaryNarration(.defaultPiper) }, 2,
                       "A primary that repeats the secondary publishes both changes")
    }

    // MARK: Migration interplay

    func testLegacyEngineStoreIsMigratedOnceByTheFirstSettingsLoad() throws {
        let defaults = try makeDefaults()
        defaults.set("system", forKey: Key.legacyPrimaryEngine)
        defaults.set("piper", forKey: Key.legacySecondaryEngine)

        defaults.set(GlobalVoiceMigration.currentVersion, forKey: GlobalVoiceMigration.versionKey)  // v1 rules only
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.primaryTtsSelection, .systemDefault)
        XCTAssertEqual(settings.secondaryTtsSelection, .defaultPiper)
        XCTAssertNil(defaults.object(forKey: Key.legacyPrimaryEngine))
        XCTAssertNil(defaults.object(forKey: Key.legacySecondaryEngine))
        XCTAssertEqual(defaults.integer(forKey: SpeechPreferenceMigration.versionKey), 1)

        // A completed migration is not re-run: a legacy key written later is ignored and kept.
        settings.selectSecondaryNarration(nil)
        defaults.set("edge", forKey: Key.legacyPrimaryEngine)
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertEqual(relaunched.primaryTtsSelection, .systemDefault)
        XCTAssertNil(relaunched.secondaryTtsSelection)
        XCTAssertEqual(defaults.string(forKey: Key.legacyPrimaryEngine), "edge")
    }

    func testUndecodableSelectionAfterMigrationFallsBackWithoutBeingOverwritten() throws {
        let defaults = try makeDefaults()
        SpeechPreferenceMigration.runIfNeeded(defaults)
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: Key.primarySelection)
        defaults.set(garbage, forKey: Key.secondarySelection)

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.primaryTtsSelection, .defaultPiper)
        XCTAssertNil(settings.secondaryTtsSelection)
        XCTAssertEqual(defaults.data(forKey: Key.primarySelection), garbage)
        XCTAssertEqual(defaults.data(forKey: Key.secondarySelection), garbage)

        settings.selectPrimaryNarration(englishPiper)
        XCTAssertEqual(saved(defaults, Key.primarySelection), englishPiper, "Only a new explicit choice replaces it")
        XCTAssertEqual(defaults.data(forKey: Key.secondarySelection), garbage)
    }

    // MARK: Conversion options

    func testConversionOptionsCarryTheSpeechPreferencesAndLocalPaths() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.allowAutomaticSystemVoiceFallback = false

        let options = NarrationConversionOptions.current(for: settings.ttsPreferences)
        XCTAssertEqual(options.engine, "piper")
        XCTAssertEqual(options.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(options.modelsRoot, LocalSpeechModelReadiness.ttsModelsRoot()?.path)
        XCTAssertEqual(options.espeakDataDirectory, Bundle.main.resourceURL?.path)
        let preferences = try XCTUnwrap(options.ttsPreferences)
        XCTAssertEqual(preferences.primary.engine, "piper")
        XCTAssertEqual(preferences.primary.modelID, "pt_BR-faber-medium")
        XCTAssertEqual(preferences.secondary?.engine, "system")
        XCTAssertFalse(preferences.allowOnlineFallback)
        XCTAssertEqual(preferences.policyVersion, 3)

        settings.selectPrimaryNarration(.systemDefault)
        let system = NarrationConversionOptions.current(for: settings.ttsPreferences)
        XCTAssertEqual(system.engine, "system")
        XCTAssertNil(system.modelID)
        XCTAssertEqual(system.modelsRoot, LocalSpeechModelReadiness.ttsModelsRoot()?.path,
                       "The models root is sent for every engine")
        XCTAssertNil(system.ttsPreferences?.secondary)
    }
}
