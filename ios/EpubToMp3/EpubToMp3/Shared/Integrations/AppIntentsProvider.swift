import AppIntents
import Foundation

// MARK: - Intent errors

private enum IntentFailure: LocalizedError {
    case noLibrary
    case bookNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noLibrary:
            return L10n.string("intents.noLibrary")
        case .bookNotFound(let title):
            return L10n.string("intents.bookNotFound", title)
        }
    }
}

// MARK: - Minimal BookEntity stub for intent context
// The intents run in-process and read from the same UserDefaults as the app,
// so we decode the real "library.books.v1" payload with a lightweight struct
// that only captures the fields we need (id, title, lastOpenedAt).

private struct IntentBookEntry: Decodable {
    let id: String
    let title: String
    let lastOpenedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, lastOpenedAt
    }
}

private struct LibraryLoader {
    private static let defaultsKey = "library.books.v1"
    private let defaults: UserDefaults

    init(sharedDefaults: UserDefaults?, standardDefaults: UserDefaults) {
        // Match LibraryStore's persistence domain. An empty shared library must
        // not revive stale books from the standard defaults domain.
        defaults = sharedDefaults ?? standardDefaults
    }

    private func loadBooks() -> [IntentBookEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([IntentBookEntry].self, from: data)) ?? []
    }

    /// Book most recently opened by the user, or nil if the library is empty.
    func mostRecentBook() -> IntentBookEntry? {
        loadBooks()
            .filter { $0.lastOpenedAt != nil }
            .max(by: { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) })
    }

    /// Fuzzy title search: returns the book whose title best matches `query`.
    /// Matches are case- and diacritic-insensitive; partial substring wins over
    /// nothing. Returns nil when the library is empty.
    func findBook(matching query: String) -> IntentBookEntry? {
        let books = loadBooks()
        guard !books.isEmpty else { return nil }
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        // Exact-match first, then substring, then closest by edit distance.
        if let exact = books.first(where: {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == q
        }) { return exact }
        let sub = books.filter {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(q)
        }
        if sub.count == 1 { return sub[0] }
        if !sub.isEmpty {
            // Return the shortest match (most specific).
            return sub.min(by: { $0.title.count < $1.title.count })
        }
        // Fall back: pick the entry whose title shares the most characters.
        return books.max(by: { Self.similarity($0.title, q) < Self.similarity($1.title, q) })
    }

    /// Simple overlap coefficient for fuzzy matching fallback.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let fa = a.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let setA = Set(fa.unicodeScalars.map { $0.value })
        let setB = Set(b.unicodeScalars.map { $0.value })
        let intersection = setA.intersection(setB).count
        guard !setA.isEmpty else { return 0 }
        return Double(intersection) / Double(setA.count)
    }
}

// MARK: - ResumeReadingIntent

/// "Continue reading" / "Resume my audiobook" — opens the most recently read
/// book directly, no parameters required. Surfaces in Siri and Shortcuts.
@available(iOS 16, macOS 13, *)
struct ResumeReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading"
    static let description = IntentDescription("Opens the audiobook you were reading most recently.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await perform(sharedDefaults: UserDefaults(suiteName: LibraryStore.appGroupID),
                          standardDefaults: .standard)
    }

    func perform(sharedDefaults: UserDefaults?, standardDefaults: UserDefaults) async throws -> some IntentResult {
        let library = LibraryLoader(sharedDefaults: sharedDefaults, standardDefaults: standardDefaults)
        guard let book = library.mostRecentBook() else {
            throw IntentFailure.noLibrary
        }
        standardDefaults.set(book.id, forKey: "intent.pendingBookId")
        return .result()
    }
}

// MARK: - OpenBookIntent

/// "Open [book name] in EpubToMp3" — fuzzy-matches the given title against
/// the local library and deep-links to that book.
@available(iOS 16, macOS 13, *)
struct OpenBookIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Book"
    static let description = IntentDescription("Opens a specific audiobook by title.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Book Title", description: "The title of the book you want to open.")
    var bookTitle: String

    func perform() async throws -> some IntentResult {
        try await perform(sharedDefaults: UserDefaults(suiteName: LibraryStore.appGroupID),
                          standardDefaults: .standard)
    }

    func perform(sharedDefaults: UserDefaults?, standardDefaults: UserDefaults) async throws -> some IntentResult {
        let library = LibraryLoader(sharedDefaults: sharedDefaults, standardDefaults: standardDefaults)
        guard let book = library.findBook(matching: bookTitle) else {
            throw IntentFailure.bookNotFound(bookTitle)
        }
        standardDefaults.set(book.id, forKey: "intent.pendingBookId")
        return .result()
    }
}

// MARK: - AppShortcutsProvider

@available(iOS 16, macOS 13, *)
struct EpubToMp3Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeReadingIntent(),
            phrases: [
                "Continue reading in \(.applicationName)",
                "Resume my audiobook in \(.applicationName)",
                "Resume reading in \(.applicationName)"
            ],
            shortTitle: "Continue Reading",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: OpenBookIntent(),
            phrases: [
                "Open a book in \(.applicationName)",
                "Open book in \(.applicationName)"
            ],
            shortTitle: "Open Book",
            systemImageName: "book"
        )
    }
}
