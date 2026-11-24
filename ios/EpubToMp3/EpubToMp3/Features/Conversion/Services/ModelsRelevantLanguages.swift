import Foundation

extension ModelsByLanguageViewState {
    /// The sections the Models screen lists directly, the language list being its own screen:
    /// the focus language (the book's), every language with a saved choice or a ready downloaded model
    /// (the always-available system voice does not count), else the first system language that has models.
    /// The result keeps the original section order.
    func relevantSections(priority: String?, systemPreferred: [String]) -> [Section] {
        let focus = priority.map(SpeechPreferences.languageKey)
        let relevant = sections.filter { section in
            section.language == focus || section.chosen != nil
                || section.rows.contains { $0.availability == .ready && !$0.selection.isSystem }
        }
        guard relevant.isEmpty else { return relevant }
        let fallback = systemPreferred.lazy.map { SpeechPreferences.languageKey($0) }
            .compactMap { key in sections.first { $0.language == key } }.first
        return fallback.map { [$0] } ?? []
    }

    func section(for language: String) -> Section? {
        let key = SpeechPreferences.languageKey(language)
        return sections.first { $0.language == key }
    }
}
