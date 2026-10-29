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
}
