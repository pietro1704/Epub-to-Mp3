import Combine
import XCTest
@testable import EpubToMp3

final class NativeSettingsProjectionTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "NativeSettingsProjection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testMigrationDistinguishesFreshDefaultsFromAnExplicitSecondaryOptOut() {
        withDefaults { defaults in
            let fresh = SpeechPreferenceMigration(defaults: defaults)
            XCTAssertEqual(fresh.primary, .piper)
            XCTAssertEqual(fresh.secondary, .system)
            XCTAssertFalse(fresh.allowOnlineFallback)
            defaults.removeObject(forKey: "secondaryAudioEngine")
            let explicitNone = SpeechPreferenceMigration(defaults: defaults)
            XCTAssertEqual(explicitNone.primary, .piper)
            XCTAssertNil(explicitNone.secondary)
            XCTAssertNil(defaults.object(forKey: "secondaryAudioEngine"))
        }
    }

    func testMigrationRejectsUnconsentedOnlineSecondaryWithoutChangingPrimary() {
        withDefaults { defaults in
            defaults.set("piper", forKey: AppSettings.audioEngineKey)
            defaults.set("edge", forKey: "secondaryAudioEngine")
            let migrated = SpeechPreferenceMigration(defaults: defaults)
            XCTAssertEqual(migrated.primary, .piper)
            XCTAssertNil(migrated.secondary)
            XCTAssertNil(defaults.string(forKey: "secondaryAudioEngine"))
        }
    }

    func testReaderOverridesDoNotChangeThePersistedLayoutChoice() {
        withDefaults { defaults in
            defaults.set("scrolling", forKey: "readerLayout")
            let legacy = ReaderLayoutPreferences(defaults: defaults, arguments: [])
            XCTAssertEqual(legacy.readerLayout, .paginated)
            let forced = ReaderLayoutPreferences(defaults: defaults, arguments: [
                "-uiTestReaderLayout", "scrolling", "-uiTestReaderFontSize", "99",
            ])
            XCTAssertEqual(forced.readerLayout, .scrolling)
            XCTAssertEqual(forced.readerFontSize, 4)
            XCTAssertFalse(defaults.bool(forKey: "readerLayout.userSet.v1"))
            XCTAssertEqual(defaults.string(forKey: "readerLayout"), "scrolling")
        }
    }

    func testCustomColorsContinuePublishingAndPersistingThroughAppSettings() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            var changes = 0
            let observation = settings.objectWillChange.sink { changes += 1 }
            settings.readerCustomColors = ((0.1, 0.2, 0.3), (0.8, 0.9, 1))
            XCTAssertGreaterThan(changes, 0)
            XCTAssertEqual(defaults.string(forKey: "readerCustomColors"), "0.1000,0.2000,0.3000,0.8000,0.9000,1.0000")
            XCTAssertEqual(AppSettings(defaults: defaults).readerCustomColors.background.1, 0.2)
            XCTAssertEqual(ReaderCustomColorCodec.decode("invalid").foreground.0, 0)
            withExtendedLifetime(observation) {}
        }
    }
}
