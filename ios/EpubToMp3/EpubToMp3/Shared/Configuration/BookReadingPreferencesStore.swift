import Foundation

/// Per-book reading preferences (READING-PREFERENCES): a book that opted in has its own `UserDefaults` suite holding
/// a full copy of the reader appearance keys, made from the default at the moment it opted in. The app-wide default is
/// never touched while that book is open, and removing the suite returns the book to the default.
final class BookReadingPreferencesStore {
    static let shared = BookReadingPreferencesStore()

    /// Every reader appearance key the settings screen edits; copied when a book opts in.
    static let readerKeys = [
        "readerFontSize", "readerFontFamily", "readerTheme", "readerAutoScroll", "readerAudioTrackingEnabled",
        "readerShowPageNumbers", "readerTextAlignment", "readerLayout", "readerLayout.userSet.v1", "readerColumns",
        "pageTurnStyle", "readerLineSpacing", "readerMargin", "readerColumnWidth", "readerCustomColors",
        "readerOverrideFontFamily", "readerOverrideFontSize", "readerOverrideColours", "readerOverrideTextAlignment",
        "readerOverrideLineSpacing", "readerBoldOverride", "readerSuppressItalic", "readerLetterSpacing", "readerWordSpacing",
    ]

    private let registry: UserDefaults
    private let suiteNamePrefix: String
    private static let registryKey = "bookReadingPreferenceBookIDs"

    init(registry: UserDefaults = .standard, suiteNamePrefix: String = "com.pietrocode.epubtomp3.book-reading-preferences") {
        self.registry = registry
        self.suiteNamePrefix = suiteNamePrefix
    }

    private var bookIDs: Set<String> {
        Set(registry.stringArray(forKey: Self.registryKey) ?? [])
    }

    func isTurnedOff(_ bookID: String) -> Bool { false }

    func hasPreferences(for bookID: String) -> Bool { bookIDs.contains(bookID) }

    func suite(for bookID: String) -> UserDefaults? {
        hasPreferences(for: bookID) ? UserDefaults(suiteName: suiteName(for: bookID)) : nil
    }

    /// Creates the book's suite as a copy of `source`'s reader keys.
    func create(for bookID: String, copying source: UserDefaults) -> UserDefaults {
        let suite = UserDefaults(suiteName: suiteName(for: bookID))!
        suite.removePersistentDomain(forName: suiteName(for: bookID))
        for key in Self.readerKeys {
            if let value = source.object(forKey: key) { suite.set(value, forKey: key) }
        }
        registry.set(bookIDs.union([bookID]).sorted(), forKey: Self.registryKey)
        return suite
    }

    func remove(_ bookID: String) {
        UserDefaults().removePersistentDomain(forName: suiteName(for: bookID))
        registry.set(bookIDs.subtracting([bookID]).sorted(), forKey: Self.registryKey)
    }

    /// A stable, filesystem-safe suite name for any book id.
    private func suiteName(for bookID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bookID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(suiteNamePrefix).\(String(hash, radix: 16))"
    }
}
