import Foundation

struct BookPronunciationDictionary: Codable, Equatable, Sendable {
    struct Rule: Codable, Equatable, Sendable { let term: String; let spoken: String }
    var rules: [Rule] = []

    static func parse(_ text: String) throws -> Self {
        let rules = try text.split(whereSeparator: \.isNewline).map { line -> Rule in
            let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw CocoaError(.formatting) }
            let term = fields[0].trimmingCharacters(in: .whitespaces)
            let spoken = fields[1].trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !spoken.isEmpty, term.count <= 200, spoken.count <= 400,
                  !term.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !spoken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw CocoaError(.formatting) }
            return Rule(term: term, spoken: spoken)
        }
        guard rules.count <= 200, Set(rules.map(\.term)).count == rules.count else { throw CocoaError(.formatting) }
        return Self(rules: rules)
    }

    var editableText: String { rules.map { "\($0.term) = \($0.spoken)" }.joined(separator: "\n") }
}

/// User-initiated edits are isolated by immutable book content identity.
struct BookPronunciationStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load(bookID: String) -> BookPronunciationDictionary {
        guard let bytes = defaults.data(forKey: "bookPronunciation.v1.\(bookID)"),
              let dictionary = try? JSONDecoder().decode(BookPronunciationDictionary.self, from: bytes)
        else { return BookPronunciationDictionary() }
        return dictionary
    }
    func save(_ dictionary: BookPronunciationDictionary, bookID: String) throws {
        let validated = try BookPronunciationDictionary.parse(dictionary.editableText)
        defaults.set(try JSONEncoder().encode(validated), forKey: "bookPronunciation.v1.\(bookID)")
    }
}
