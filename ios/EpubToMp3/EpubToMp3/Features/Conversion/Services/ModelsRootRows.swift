import Foundation

/// A2 (design 2026-11-24): the root of Models lists "the voice for each language". This is its pure row model:
/// which languages appear, in which order, what each one resolves to and whether a book of the library is left
/// without a voice. The views only draw it.
enum ModelsRootRows {
    /// Why a language is on the list (a language can have several reasons).
    struct Reasons: OptionSet, Equatable, Sendable {
        let rawValue: Int
        /// The user's system languages.
        static let system = Reasons(rawValue: 1 << 0)
        /// At least one book of the library is in it.
        static let book = Reasons(rawValue: 1 << 1)
        /// The listener chose a voice for it.
        static let choice = Reasons(rawValue: 1 << 2)
        /// A local voice for it is installed.
        static let installed = Reasons(rawValue: 1 << 3)
    }

    struct Row: Equatable, Identifiable, Sendable {
        /// Base language tag (`pt`).
        let language: String
        let reasons: Reasons
        /// What the language resolves to now; `nil` while it was not resolved.
        let resolution: LanguageModelResolution?
        /// A book of the library is in this language and nothing can read it: the row warns.
        let needsVoice: Bool
        var id: String { language }
    }

    struct Input {
        var systemLanguages: [String] = []
        var bookLanguages: [String] = []
        var choices: [String: TtsSelection] = [:]
        var installedLanguages: [String] = []
        var resolution: (String) -> LanguageModelResolution? = { _ in nil }
    }

    /// System languages first, then the library's, then the languages with a choice or an installed voice;
    /// each base language once, in that order.
    static func rows(_ input: Input) -> [Row] {
        var order: [String] = []
        var reasons: [String: Reasons] = [:]
        func add(_ tag: String, _ reason: Reasons) {
            let key = SpeechPreferences.languageKey(tag.trimmingCharacters(in: .whitespaces))
            guard !key.isEmpty else { return }
            if reasons[key] == nil { order.append(key) }
            reasons[key, default: []].formUnion(reason)
        }
        input.systemLanguages.forEach { add($0, .system) }
        input.bookLanguages.forEach { add($0, .book) }
        input.choices.keys.sorted().forEach { add($0, .choice) }
        input.installedLanguages.forEach { add($0, .installed) }
        return order.map { language in
            let resolution = input.resolution(language)
            let why = reasons[language] ?? []
            return Row(language: language, reasons: why, resolution: resolution,
                       needsVoice: why.contains(.book) && resolution?.status == .missingModel)
        }
    }
}
