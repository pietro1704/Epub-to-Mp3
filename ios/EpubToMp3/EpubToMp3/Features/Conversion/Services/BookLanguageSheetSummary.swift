import Foundation

/// A3 (design 2026-11-24): what the book language sheet says about the detection, and the order of its list.
struct BookLanguageSheetSummary: Equatable {
    /// "Portuguese 98%. Also quoted: French, Latin."
    let detected: String
    /// Set when the file declares another language than the text has. It is reported, never alerted.
    let conflict: String?

    var text: String { [detected, conflict].compactMap { $0 }.joined(separator: "\n") }

    init?(analysis: BookLanguageAnalysis, uiLocale: Locale = .current) {
        guard let profile = analysis.profile else { return nil }
        func name(_ tag: String) -> String {
            ModelLanguageOrder.displayName(ModelLanguageOrder.baseTag(tag), in: uiLocale)
        }
        let shares = profile.languages.sorted { $0.fraction > $1.fraction }
            .map { "\(name($0.language)) \(Int(($0.fraction * 100).rounded()))%" }
        var parts = [L10n.string("language.detected", shares.isEmpty ? name(profile.primary) : shares.joined(separator: ", "))]
        if !profile.incidental.isEmpty {
            parts.append(L10n.string("language.quoted", profile.incidental.map(name).joined(separator: ", ")))
        }
        detected = parts.joined(separator: " ")
        let declared = analysis.declared.map(ModelLanguageOrder.baseTag) ?? ""
        // "und" and empty tags declare nothing.
        conflict = declared.isEmpty || declared == "und" || declared == ModelLanguageOrder.baseTag(profile.primary)
            ? nil : L10n.string("language.conflict", name(declared), name(profile.primary))
    }

    /// The sheet's tags in the order of the Models language screen; the variants of a language follow it.
    static func ordered(_ tags: [String], catalog: [CatalogLanguage],
                        systemPreferred: [String] = Locale.preferredLanguages,
                        uiLocale: Locale = .current) -> [String] {
        let variants = Dictionary(grouping: tags, by: ModelLanguageOrder.baseTag)
        let ranks = Dictionary(catalog.map { ($0.tag.lowercased(), $0.popularityRank) }, uniquingKeysWith: { first, _ in first })
        let languages = variants.keys.map { CatalogLanguage(tag: $0, modelCount: 0, popularityRank: ranks[$0] ?? nil) }
        return ModelLanguageOrder.sections(languages: languages, systemPreferred: systemPreferred, uiLocale: uiLocale).all
            .flatMap { base in (variants[base] ?? []).sorted { ($0.count, $0) < ($1.count, $1) } }
    }
}
