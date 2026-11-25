import Combine
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// The speech rules on their owner, without `AppSettings`; the
/// `AppSettings` surface is pinned by `AppSettingsSpeechCharacterizationTests`.
final class SpeechPreferencesTests: XCTestCase {
    private typealias Key = SpeechPreferenceMigration.Key
    private var suites: [String] = []
    private let englishPiper = TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil)

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "speech-preferences-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// These cases cover the load rules alone; GlobalVoiceMigrationTests covers the one that moves the primary.
    private func markGlobalVoiceMigrationDone(_ defaults: UserDefaults) {
        defaults.set(GlobalVoiceMigration.currentVersion, forKey: GlobalVoiceMigration.versionKey)
    }

    func testLoadingRunsTheMigrationAndReadsTheSavedChoices() throws {
        let defaults = try makeDefaults()
        defaults.set("edge", forKey: Key.legacyPrimaryEngine)
        defaults.set(true, forKey: Key.onlineFallbackConsent)
        defaults.set(false, forKey: SpeechPreferences.automaticSystemFallbackKey)
        markGlobalVoiceMigrationDone(defaults)

        let speech = SpeechPreferences(defaults: defaults)
        XCTAssertEqual(speech.primaryTtsSelection, .edgeDefault)
        XCTAssertTrue(speech.allowOnlineAudioFallback)
        XCTAssertFalse(speech.allowAutomaticSystemVoiceFallback)
        XCTAssertEqual(speech.ttsPreferences.policyVersion, 3)
        XCTAssertNil(defaults.object(forKey: Key.legacyPrimaryEngine))
        XCTAssertEqual(defaults.integer(forKey: SpeechPreferenceMigration.versionKey), SpeechPreferenceMigration.currentVersion)
    }

    func testSecondaryRulesAndConsentRevocation() throws {
        let defaults = try makeDefaults()
        let speech = SpeechPreferences(defaults: defaults)

        speech.selectSecondaryNarration(.defaultPiper)
        XCTAssertNil(speech.secondaryTtsSelection)
        speech.selectSecondaryNarration(.edgeDefault)
        XCTAssertNil(speech.secondaryTtsSelection)

        speech.allowOnlineAudioFallback = true
        speech.selectSecondaryNarration(.edgeDefault)
        XCTAssertEqual(SpeechPreferences(defaults: defaults).secondaryTtsSelection, .edgeDefault)
        speech.allowOnlineAudioFallback = false
        XCTAssertNil(speech.secondaryTtsSelection)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))

        speech.selectSecondaryNarration(englishPiper)
        speech.selectPrimaryNarration(englishPiper)
        XCTAssertNil(speech.secondaryTtsSelection)
        XCTAssertEqual(SpeechPreferences(defaults: defaults).primaryTtsSelection, englishPiper)
    }

    func testEveryMutationPublishesBeforeTheValueChanges() throws {
        let speech = SpeechPreferences(defaults: try makeDefaults())
        var seenBeforeChange: [TtsSelection] = []
        let observation = speech.objectWillChange.sink { seenBeforeChange.append(speech.primaryTtsSelection) }
        speech.selectPrimaryNarration(englishPiper)
        XCTAssertEqual(seenBeforeChange, [.defaultPiper])
        withExtendedLifetime(observation) {}
    }

    // MARK: EDGE-PRIMARY-MIGRATION-TO-PIPER

    private func defaultsSuite() throws -> (UserDefaults, String) {
        let name = "speech-prefs-migration-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testAnEdgePrimarySavedWithoutConsentMigratesToDefaultPiperAndIsSaved() throws {
        let (defaults, name) = try defaultsSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(TtsSelection.edgeDefault), forKey: SpeechPreferenceMigration.Key.primarySelection)
        defaults.set(try JSONEncoder().encode(TtsSelection.systemDefault), forKey: SpeechPreferenceMigration.Key.secondarySelection)
        defaults.set(false, forKey: SpeechPreferenceMigration.Key.onlineFallbackConsent)
        defaults.set(true, forKey: SpeechPreferences.automaticSystemFallbackKey)
        let preferences = SpeechPreferences(defaults: defaults)
        XCTAssertEqual(preferences.primaryTtsSelection.engine, "piper")
        XCTAssertEqual(preferences.primaryTtsSelection.modelID, TtsSelection.defaultPiperModelID)
        XCTAssertEqual(preferences.secondaryTtsSelection?.engine, "system", "The reserve voice is preserved")
        XCTAssertFalse(preferences.allowOnlineAudioFallback)
        // Saved: a fresh load sees Piper without migrating again.
        let reloaded = SpeechPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.primaryTtsSelection.engine, "piper")
        XCTAssertEqual(SpeechPreferences(defaults: defaults).ttsPreferences.primary.engine, "piper")
    }

    func testAnEdgePrimaryWithConsentIsKeptAndOtherPrimariesAreUntouched() throws {
        let (defaults, name) = try defaultsSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(TtsSelection.edgeDefault), forKey: SpeechPreferenceMigration.Key.primarySelection)
        defaults.set(true, forKey: SpeechPreferenceMigration.Key.onlineFallbackConsent)
        markGlobalVoiceMigrationDone(defaults)
        XCTAssertEqual(SpeechPreferences(defaults: defaults).primaryTtsSelection.engine, "edge")
        let (system, systemName) = try defaultsSuite()
        defer { system.removePersistentDomain(forName: systemName) }
        system.set(try JSONEncoder().encode(TtsSelection.systemDefault), forKey: SpeechPreferenceMigration.Key.primarySelection)
        markGlobalVoiceMigrationDone(system)
        XCTAssertEqual(SpeechPreferences(defaults: system).primaryTtsSelection.engine, "system")
    }

    func testAReserveThatWouldRepeatTheMigratedPrimaryIsDropped() throws {
        let (defaults, name) = try defaultsSuite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(TtsSelection.edgeDefault), forKey: SpeechPreferenceMigration.Key.primarySelection)
        defaults.set(try JSONEncoder().encode(TtsSelection.defaultPiper), forKey: SpeechPreferenceMigration.Key.secondarySelection)
        XCTAssertNil(SpeechPreferences(defaults: defaults).secondaryTtsSelection)
    }
    /// FOOTNOTE-NARRATION: notes are read inline unless the listener turns that off; Rust applies the choice.
    func testFootnotesAreReadInlineUntilTheListenerTurnsThemOff() throws {
        let defaults = try makeDefaults()
        markGlobalVoiceMigrationDone(defaults)
        let speech = SpeechPreferences(defaults: defaults)
        XCTAssertTrue(speech.narratesFootnotes)
        XCTAssertNil(speech.ttsPreferences.footnoteNarration, "Inline is the Rust default and is not sent")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(speech.ttsPreferences), as: UTF8.self)
            .contains("footnote_narration"))

        speech.narratesFootnotes = false
        let reloaded = SpeechPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.narratesFootnotes, "The choice is saved")
        XCTAssertEqual(reloaded.ttsPreferences.footnoteNarration, .skip)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(reloaded.ttsPreferences), as: UTF8.self)
            .contains(#""footnote_narration":"skip""#))
        let decoded = try JSONDecoder().decode(TtsPreferences.self, from: Data(#"{"primary":{"engine":"piper"},"allow_online_fallback":false,"footnote_narration":"skip"}"#.utf8))
        XCTAssertEqual(decoded.footnoteNarration, .skip)
    }
}
