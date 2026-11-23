import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// UI tests that change narration or consent run on a throwaway suite; the real
/// preferences of the app installation must never be read or written by them.
final class SettingsDefaultsSourceTests: XCTestCase {
    private typealias Key = SpeechPreferenceMigration.Key
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func makeSuite() throws -> (name: String, defaults: UserDefaults) {
        let name = "settings-defaults-source-\(UUID().uuidString)"
        suites.append(name)
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testWithoutTheLaunchArgumentTheStandardDefaultsAreUsed() throws {
        let standard = try makeSuite().defaults
        let resolved = SettingsDefaultsSource.resolve(arguments: ["-uiTestFixture"], standard: standard)
        XCTAssertTrue(resolved === standard)
    }

    func testIsolatedLaunchWritesNarrationAndConsentWithoutTouchingTheRealDefaults() throws {
        let real = try makeSuite()
        let realPreferences = SpeechPreferences(defaults: real.defaults)
        realPreferences.selectPrimaryNarration(.defaultPiper)
        realPreferences.allowOnlineAudioFallback = false
        let realBefore = real.defaults.persistentDomain(forName: real.name) as NSDictionary?
        let appStandardBefore = Self.speechSnapshot(UserDefaults.standard)

        let isolatedName = "settings-defaults-source-isolated-\(UUID().uuidString)"
        suites.append(isolatedName)
        let isolated = SettingsDefaultsSource.resolve(
            arguments: [SettingsDefaultsSource.launchArgument], standard: real.defaults, suiteName: isolatedName)
        XCTAssertFalse(isolated === real.defaults)

        let isolatedPreferences = SpeechPreferences(defaults: isolated)
        isolatedPreferences.selectPrimaryNarration(.edgeDefault)
        isolatedPreferences.allowOnlineAudioFallback = true

        XCTAssertEqual(isolated.bool(forKey: Key.onlineFallbackConsent), true, "The isolated suite takes the write.")
        XCTAssertNotNil(isolated.data(forKey: Key.primarySelection))
        let realAfter = real.defaults.persistentDomain(forName: real.name) as NSDictionary?
        XCTAssertEqual(realAfter, realBefore, "The real defaults must be exactly as they were.")
        XCTAssertEqual(real.defaults.bool(forKey: Key.onlineFallbackConsent), false)
        XCTAssertEqual(Self.speechSnapshot(UserDefaults.standard), appStandardBefore,
                       "The app's own standard defaults must not change either.")
    }

    func testIsolatedSuiteStartsEmptyOnEveryLaunch() throws {
        let name = "settings-defaults-source-empty-\(UUID().uuidString)"
        suites.append(name)
        let arguments = [SettingsDefaultsSource.launchArgument]
        let standard = try makeSuite().defaults
        let first = SettingsDefaultsSource.resolve(arguments: arguments, standard: standard, suiteName: name)
        first.set(true, forKey: Key.onlineFallbackConsent)
        let second = SettingsDefaultsSource.resolve(arguments: arguments, standard: standard, suiteName: name)
        XCTAssertNil(second.object(forKey: Key.onlineFallbackConsent))
    }

    func testSpeechSelectionArgumentSeedsOnlyTheIsolatedSuite() throws {
        let standard = try makeSuite().defaults
        let name = "settings-defaults-source-seed-\(UUID().uuidString)"
        suites.append(name)
        let arguments = [SettingsDefaultsSource.speechSelectionArgument, "piper:en_US-ljspeech-high"]
        let resolved = SettingsDefaultsSource.resolve(arguments: arguments, standard: standard, suiteName: name)
        XCTAssertFalse(resolved === standard)
        let preferences = SpeechPreferences(defaults: resolved)
        XCTAssertEqual(preferences.primaryTtsSelection,
                       TtsSelection(engine: "piper", modelID: "en_US-ljspeech-high", voice: nil))
        XCTAssertFalse(preferences.allowOnlineAudioFallback)
        XCTAssertNotEqual(preferences.secondaryTtsSelection?.engine, "edge")
        XCTAssertNil(standard.object(forKey: Key.primarySelection), "The real defaults are not seeded.")
        XCTAssertNil(SettingsDefaultsSource.seededPrimary([SettingsDefaultsSource.speechSelectionArgument, "bogus"]))
    }

    private static func speechSnapshot(_ defaults: UserDefaults) -> [String: Data?] {
        [Key.primarySelection: defaults.data(forKey: Key.primarySelection),
         Key.secondarySelection: defaults.data(forKey: Key.secondarySelection),
         Key.onlineFallbackConsent: defaults.object(forKey: Key.onlineFallbackConsent).map { Data("\($0)".utf8) }]
    }
}
