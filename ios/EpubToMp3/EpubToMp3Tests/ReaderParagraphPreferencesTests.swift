import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ReaderParagraphPreferencesTests: XCTestCase {
    func testNewReaderUsesPublisherStyleAndLegacyChoicesRemainExplicit() throws {
        let suite = "paragraph-preferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ReaderParagraphPreferences(defaults: defaults).overridesAlignment)
        XCTAssertFalse(ReaderParagraphPreferences(defaults: defaults).overridesLineSpacing)
        defaults.set("justified", forKey: "readerTextAlignment")
        defaults.set(6.0, forKey: "readerLineSpacing")
        XCTAssertTrue(ReaderParagraphPreferences(defaults: defaults).overridesAlignment)
        XCTAssertTrue(ReaderParagraphPreferences(defaults: defaults).overridesLineSpacing)
    }

    func testRestoreOriginalPersistsDespiteRetainedControlValues() throws {
        let suite = "paragraph-reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("left", forKey: "readerTextAlignment")
        defaults.set(12, forKey: "readerLineSpacing")
        defaults.set(false, forKey: "readerOverrideTextAlignment")
        defaults.set(false, forKey: "readerOverrideLineSpacing")
        XCTAssertFalse(ReaderParagraphPreferences(defaults: defaults).overridesAlignment)
        XCTAssertFalse(ReaderParagraphPreferences(defaults: defaults).overridesLineSpacing)
    }

    #if !APP_FOUNDATION_HOST_TESTS
    /// Regression: loading the default line spacing wrote `readerLineSpacing`
    /// during `AppSettings.init`, so the legacy-key rule immediately treated a
    /// fresh install as an explicit line-spacing override (and persisted it).
    func testFreshSettingsHonorPublisherParagraphsAcrossLaunches() throws {
        let suite = "paragraph-fresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(defaults: defaults)
        XCTAssertFalse(first.readerOverrideLineSpacing, "A new reader must keep publisher line spacing.")
        XCTAssertFalse(first.readerOverrideTextAlignment)
        XCTAssertNil(defaults.object(forKey: "readerLineSpacing"),
                     "Loading the default value must not record a user line-spacing choice.")
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.readerOverrideLineSpacing)
        XCTAssertEqual(relaunched.readerLineSpacing, 6)

        relaunched.readerLineSpacing = 10
        XCTAssertTrue(relaunched.readerOverrideLineSpacing, "An explicit choice still overrides the publisher.")
        XCTAssertTrue(AppSettings(defaults: defaults).readerOverrideLineSpacing)
        XCTAssertEqual(AppSettings(defaults: defaults).readerLineSpacing, 10)
    }
    #endif
}
