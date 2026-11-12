import Foundation

struct PassageLanguageCorrection: Codable, Equatable, Sendable {
    let chapterIndex: Int
    let start: Int
    let end: Int
    let language: String
    enum CodingKeys: String, CodingKey { case start, end, language; case chapterIndex = "chapter_index" }
}

struct BookLanguageDecision: Codable, Equatable {
    var bookLanguage: String?
    var passages: [PassageLanguageCorrection] = []
}

/// User corrections belong to a source-book identity; automatic analysis stays in Rust.
struct BookLanguageCorrections {
    static let didChange = Notification.Name("BookLanguageCorrections.didChange")
    private static let key = "book.languageCorrections.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func decision(bookID: String) throws -> BookLanguageDecision {
        try decisions()[bookID] ?? BookLanguageDecision()
    }

    func set(_ language: String?, bookID: String, passage: PassageLanguageCorrection? = nil) throws {
        var decisions = try decisions()
        var decision = decisions[bookID] ?? BookLanguageDecision()
        if let passage {
            decision.passages = decision.passages.flatMap { previous -> [PassageLanguageCorrection] in
                guard previous.chapterIndex == passage.chapterIndex,
                      previous.start < passage.end, passage.start < previous.end else { return [previous] }
                var retained: [PassageLanguageCorrection] = []
                if previous.start < passage.start {
                    retained.append(.init(chapterIndex: previous.chapterIndex,
                        start: previous.start, end: passage.start, language: previous.language))
                }
                if previous.end > passage.end {
                    retained.append(.init(chapterIndex: previous.chapterIndex,
                        start: passage.end, end: previous.end, language: previous.language))
                }
                return retained
            }
            if let language, !language.isEmpty {
                decision.passages.append(PassageLanguageCorrection(chapterIndex: passage.chapterIndex,
                    start: passage.start, end: passage.end, language: language))
            }
        } else { decision.bookLanguage = language.flatMap { $0.isEmpty ? nil : $0 } }
        decisions[bookID] = decision
        defaults.set(try JSONEncoder().encode(decisions), forKey: Self.key)
        NotificationCenter.default.post(name: Self.didChange, object: nil, userInfo: ["bookID": bookID])
    }

    func applying(to options: ConversionOptions, bookID: String) throws -> ConversionOptions {
        let decision = try decision(bookID: bookID)
        var captured = options
        if captured.language?.isEmpty != false { captured.language = decision.bookLanguage }
        captured.languageOverrides = decision.passages + (captured.languageOverrides ?? [])
        return captured
    }

    private func decisions() throws -> [String: BookLanguageDecision] {
        guard let stored = defaults.data(forKey: Self.key) else { return [:] }
        return try JSONDecoder().decode([String: BookLanguageDecision].self, from: stored)
    }
}

struct BookLanguageUncertain: Decodable, Sendable {
    let chapterIndex: Int?
    let start: Int?
    let end: Int?
    enum CodingKeys: String, CodingKey { case start, end; case chapterIndex = "chapter_index" }
    static func decode(_ error: Error) -> Self? {
        guard case .conversionFailed(let reason) = error as? EmbeddedConverterError,
              let start = reason.range(of: "[[book_language_uncertain_v1]]"),
              let end = reason.range(of: "[[/book_language_uncertain_v1]]", range: start.upperBound..<reason.endIndex) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(reason[start.upperBound..<end.lowerBound].utf8))
    }
    func passage(language: String) -> PassageLanguageCorrection? {
        guard let chapterIndex, let start, let end, chapterIndex >= 0, start >= 0, end > start else { return nil }
        return .init(chapterIndex: chapterIndex, start: start, end: end, language: language)
    }
}
