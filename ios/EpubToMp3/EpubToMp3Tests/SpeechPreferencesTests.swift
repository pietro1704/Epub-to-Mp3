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

    func testLoadingRunsTheMigrationAndReadsTheSavedChoices() throws {
        let defaults = try makeDefaults()
        defaults.set("edge", forKey: Key.legacyPrimaryEngine)
        defaults.set(true, forKey: Key.onlineFallbackConsent)
        defaults.set(false, forKey: SpeechPreferences.automaticSystemFallbackKey)

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
}
