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

/// The words of the Aa screen's mode line and the bookkeeping the screens read.
final class ReadingPreferenceScopeTests: XCTestCase {
    func testScopeIsKnownOnlyWhileABookIsOpen() throws {
        let name = "scope-flag-\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { app.removePersistentDomain(forName: name) }
        let books = BookReadingPreferencesStore(registry: app, suiteNamePrefix: "scope-flag-\(UUID().uuidString)")
        addTeardownBlock { books.remove("book-a") }
        let settings = AppSettings(defaults: app)
        XCTAssertFalse(settings.isInBookScope, "Settings screen: the default for all books")
        settings.enterBookScope("book-a", store: books)
        XCTAssertTrue(settings.isInBookScope)
        XCTAssertEqual(settings.readingPreferenceModeTitleKey, "readerSettings.scope.default")
        settings.useOnlyForThisBook(store: books)
        XCTAssertEqual(settings.readingPreferenceModeTitleKey, "readerSettings.scope.thisBook")
        settings.leaveBookScope()
        XCTAssertFalse(settings.isInBookScope)
    }

    func testEveryLocaleStatesTheModeAndTheChoice() {
        let keys = ["readerSettings.scope.default", "readerSettings.scope.thisBook", "readerSettings.scope.toggle",
                    "readerSettings.scope.defaultHint", "readerSettings.scope.thisBookHint"]
        for key in keys {
            for localization in ["en", "pt-BR", "es"] {
                XCTAssertNotEqual(L10n.string(key, bundle: L10n.localizationBundle(localization)), key, "\(key) in \(localization)")
            }
        }
    }
}

#if os(macOS)
import AppKit

/// The macOS Aa popover states its mode on top and lets the reader keep the settings for this book only.
@MainActor
final class MacReadingPreferenceScopeTests: XCTestCase {
    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews { if let found = find(identifier, in: subview) { return found } }
        return nil
    }

    private func content(_ popover: NSPopover) -> NSView? {
        guard let scroll = popover.contentViewController?.view as? NSScrollView else { return nil }
        return scroll.documentView
    }

    func testThePopoverStatesTheModeAndTheCheckboxKeepsTheSettingsForThisBookOnly() throws {
        let name = "mac-scope-\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { app.removePersistentDomain(forName: name) }
        let books = BookReadingPreferencesStore(registry: app, suiteNamePrefix: "mac-scope-\(UUID().uuidString)")
        addTeardownBlock { books.remove("book-a") }
        let settings = AppSettings(defaults: app)
        settings.readerTheme = .sepia
        settings.enterBookScope("book-a", store: books)
        let popover = NSPopover()
        let presentation = MacReaderSettingsPresentation(settings: settings, popover: popover, bookPreferences: books)
        presentation.prepareForTesting()
        var root = try XCTUnwrap(content(popover))
        let mode = try XCTUnwrap(find("readerSettings.scope.mode", in: root) as? NSTextField)
        XCTAssertEqual(mode.stringValue, L10n.string("readerSettings.scope.default"))
        let checkbox = try XCTUnwrap(find("readerSettings.scope.bookOnly", in: root) as? NSButton)
        XCTAssertEqual(checkbox.state, .off)

        checkbox.performClick(nil)
        XCTAssertTrue(settings.isBookSpecific)
        root = try XCTUnwrap(content(popover))
        XCTAssertEqual((find("readerSettings.scope.mode", in: root) as? NSTextField)?.stringValue,
                       L10n.string("readerSettings.scope.thisBook"), "The mode line follows the choice")
        settings.readerTheme = .dark
        XCTAssertEqual(app.string(forKey: "readerTheme"), ReaderTheme.sepia.rawValue, "The default is untouched")

        let again = try XCTUnwrap(find("readerSettings.scope.bookOnly", in: root) as? NSButton)
        XCTAssertEqual(again.state, .on)
        again.performClick(nil)
        XCTAssertFalse(settings.isBookSpecific, "Use default")
        XCTAssertEqual(settings.readerTheme, .sepia)
    }

    func testWithoutAnOpenBookThePopoverHasNoScopeControls() throws {
        let name = "mac-scope-none-\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { app.removePersistentDomain(forName: name) }
        let popover = NSPopover()
        let presentation = MacReaderSettingsPresentation(settings: AppSettings(defaults: app), popover: popover)
        presentation.prepareForTesting()
        XCTAssertNil(find("readerSettings.scope.bookOnly", in: try XCTUnwrap(content(popover))))
    }
}
#endif

#if os(iOS)
import UIKit

/// The iOS Aa sheet states its mode on top and keeps the settings for this book only on request (UIKit; 16e).
@MainActor
final class ReaderSettingsScopeHeaderTests: XCTestCase {
    func testTheHeaderStatesTheModeAndTheSwitchKeepsTheSettingsForThisBook() throws {
        let name = "ios-scope-\(UUID().uuidString)"
        let app = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { app.removePersistentDomain(forName: name) }
        let books = BookReadingPreferencesStore(registry: app, suiteNamePrefix: "ios-scope-\(UUID().uuidString)")
        addTeardownBlock { books.remove("book-a") }
        let settings = AppSettings(defaults: app)
        let controller = ReaderSettingsScreenController(settings: settings)
        controller.loadViewIfNeeded()
        XCTAssertNil(controller.tableView.tableHeaderView, "No book open: the default for all books, no scope controls")

        settings.enterBookScope("book-a", store: books)
        controller.refresh()
        let header = try XCTUnwrap(controller.tableView.tableHeaderView)
        func find<T: UIView>(_ identifier: String, as _: T.Type) -> T? {
            func walk(_ view: UIView) -> T? {
                if view.accessibilityIdentifier == identifier, let match = view as? T { return match }
                for subview in view.subviews { if let found = walk(subview) { return found } }
                return nil
            }
            return walk(header)
        }
        XCTAssertEqual(find("readerSettings.scope.mode", as: UILabel.self)?.text, L10n.string("readerSettings.scope.default"))
        let toggle = try XCTUnwrap(find("readerSettings.scope.bookOnly", as: UISwitch.self))
        XCTAssertFalse(toggle.isOn)
        XCTAssertGreaterThan(header.frame.height, 60, "The header lays out its lines")
    }
}
#endif
