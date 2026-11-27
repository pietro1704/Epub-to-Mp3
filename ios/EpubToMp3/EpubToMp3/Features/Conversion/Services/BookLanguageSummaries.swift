import Foundation

/// The main language Rust found in each analyzed book, kept so the Models root can list the library's
/// languages without parsing books again. A book that was never analyzed is not listed.
struct BookLanguageSummaries {
    private static let key = "book.languageSummaries.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(_ language: String?, bookID: String) {
        guard let language, !language.isEmpty else { return }
        var stored = summaries
        guard stored[bookID] != language else { return }
        stored[bookID] = language
        defaults.set(stored, forKey: Self.key)
    }

    func remove(bookID: String) {
        var stored = summaries
        guard stored.removeValue(forKey: bookID) != nil else { return }
        defaults.set(stored, forKey: Self.key)
    }

    /// The user's correction of a book wins over its analysis. Nil for a book never analyzed or corrected.
    func language(bookID: String, corrections: BookLanguageCorrections) -> String? {
        (try? corrections.decision(bookID: bookID))?.bookLanguage ?? summaries[bookID]
    }

    /// One entry per analyzed book, in a stable order; the user's correction of a book wins over its analysis.
    func languages(corrections: BookLanguageCorrections) -> [String] {
        summaries.sorted { $0.key < $1.key }.map { bookID, analyzed in
            (try? corrections.decision(bookID: bookID))?.bookLanguage ?? analyzed
        }
    }

    private var summaries: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
