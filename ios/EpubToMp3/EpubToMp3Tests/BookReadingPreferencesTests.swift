import XCTest
@testable import EpubToMp3

/// READING-PREFERENCES core: a book can have its own reader appearance preferences; the default for every other book
/// never changes while it is open, and "Use default" returns the book to the default.
final class BookReadingPreferencesTests: XCTestCase {
    private var suiteNames: [String] = []

    private func defaults() throws -> UserDefaults {
        let name = "book-reading-prefs-\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func store(_ app: UserDefaults) -> BookReadingPreferencesStore {
        let prefix = "bookprefs-\(UUID().uuidString)"
        suiteNames.append(prefix)
        let books = BookReadingPreferencesStore(registry: app, suiteNamePrefix: prefix)
        addTeardownBlock { ["book-a", "book-b", "book-z"].forEach(books.remove) }
        return books
    }

    override func tearDown() {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        super.tearDown()
    }

    func testABookWithoutItsOwnPreferencesUsesAndEditsTheDefault() throws {
        let app = try defaults(); let books = store(app)
        let settings = AppSettings(defaults: app)
        settings.readerTheme = .sepia
        settings.enterBookScope("book-a", store: books)
        XCTAssertFalse(settings.isBookSpecific)
        XCTAssertEqual(settings.readerTheme, .sepia)
        settings.readerTheme = .dark
        XCTAssertEqual(app.string(forKey: "readerTheme"), ReaderTheme.dark.rawValue, "No override: the edit is the default")
    }

    func testOnlyThisBookKeepsItsOwnValuesAndLeavesTheDefaultAlone() throws {
        let app = try defaults(); let books = store(app)
        let settings = AppSettings(defaults: app)
        settings.readerTheme = .sepia
        settings.readerFontSize = 1
        settings.enterBookScope("book-a", store: books)
        settings.useOnlyForThisBook(store: books)
        XCTAssertTrue(settings.isBookSpecific)
        XCTAssertEqual(settings.readerTheme, .sepia, "The book starts from the current default")
        settings.readerTheme = .dark
        settings.readerFontSize = 4
        XCTAssertEqual(app.string(forKey: "readerTheme"), ReaderTheme.sepia.rawValue, "The default is untouched")
        XCTAssertEqual(app.integer(forKey: "readerFontSize"), 1)

        settings.leaveBookScope()
        XCTAssertEqual(settings.readerTheme, .sepia, "Another book sees the default again")
        XCTAssertEqual(settings.readerFontSize, 1)
        settings.enterBookScope("book-a", store: books)
        XCTAssertTrue(settings.isBookSpecific)
        XCTAssertEqual(settings.readerTheme, .dark, "The book's own values come back")
        XCTAssertEqual(settings.readerFontSize, 4)
    }

    func testUseDefaultReturnsTheBookToTheDefaultAndForgetsItsValues() throws {
        let app = try defaults(); let books = store(app)
        let settings = AppSettings(defaults: app)
        settings.readerTheme = .sepia
        settings.enterBookScope("book-a", store: books)
        settings.useOnlyForThisBook(store: books)
        settings.readerTheme = .dark
        settings.useDefaultForThisBook(store: books)
        XCTAssertFalse(settings.isBookSpecific)
        XCTAssertEqual(settings.readerTheme, .sepia)
        settings.leaveBookScope(); settings.enterBookScope("book-a", store: books)
        XCTAssertFalse(settings.isBookSpecific, "The override is gone for good")
        XCTAssertEqual(settings.readerTheme, .sepia)
    }

    func testBooksAreIndependentAndOtherSettingsAreNotScoped() throws {
        let app = try defaults(); let books = store(app)
        let settings = AppSettings(defaults: app)
        settings.enterBookScope("book-a", store: books)
        settings.useOnlyForThisBook(store: books)
        settings.readerLineSpacing = 12
        settings.playbackForwardSeconds = 45
        settings.leaveBookScope()
        settings.enterBookScope("book-b", store: books)
        XCTAssertFalse(settings.isBookSpecific)
        XCTAssertNotEqual(settings.readerLineSpacing, 12, "Book B does not inherit book A's spacing")
        XCTAssertEqual(settings.playbackForwardSeconds, 45, "Playback settings are not per-book")
        XCTAssertEqual(app.double(forKey: AppSettings.playbackForwardSecondsKey), 45)
    }

    func testAnInstalledOverrideIsKnownAfterARelaunch() throws {
        let app = try defaults(); let books = store(app)
        let first = AppSettings(defaults: app)
        first.enterBookScope("book-a", store: books)
        first.useOnlyForThisBook(store: books)
        first.readerMargin = 40
        XCTAssertTrue(books.hasPreferences(for: "book-a"))
        let relaunched = AppSettings(defaults: app)
        relaunched.enterBookScope("book-a", store: books)
        XCTAssertTrue(relaunched.isBookSpecific)
        XCTAssertEqual(relaunched.readerMargin, 40)
        XCTAssertFalse(books.hasPreferences(for: "book-z"))
    }
}
