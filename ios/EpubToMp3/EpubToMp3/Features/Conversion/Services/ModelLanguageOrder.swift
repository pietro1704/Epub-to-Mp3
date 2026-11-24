import Foundation

/// The order of the languages on the Models language screen (CONTEXT.md, "Models screen language order"):
/// (1) the languages of the system, in the system's own order; (2) the most popular languages by the catalog's
/// `popularity_rank` (the one list shared by every client, owned by the Rust catalog); (3) every other language
/// alphabetically in the language of the UI. Each catalog language appears exactly once.
enum ModelLanguageOrder {
    struct Sections: Equatable {
        var system: [String]
        var popular: [String]
        var others: [String]
        var all: [String] { system + popular + others }
    }

    /// "pt-BR" -> "pt", "zh_Hans_CN" -> "zh": the catalog is keyed by base language.
    static func baseTag(_ identifier: String) -> String {
        let first = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? identifier
        return first.lowercased()
    }

    static func sections(languages: [CatalogLanguage], systemPreferred: [String] = Locale.preferredLanguages,
                         uiLocale: Locale = .current) -> Sections {
        let available = Dictionary(languages.map { ($0.tag.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var placed = Set<String>()
        var system: [String] = []
        for identifier in systemPreferred {
            let tag = baseTag(identifier)
            guard let language = available[tag], placed.insert(tag).inserted else { continue }
            system.append(language.tag)
        }
        let remaining = languages.filter { !placed.contains($0.tag.lowercased()) }
        let popular = remaining.filter { $0.popularityRank != nil }
            .sorted { ($0.popularityRank ?? 0, $0.tag) < ($1.popularityRank ?? 0, $1.tag) }
        let others = remaining.filter { $0.popularityRank == nil }
            .sorted { first, second in
                let order = displayName(first.tag, in: uiLocale).localizedStandardCompare(displayName(second.tag, in: uiLocale))
                return order == .orderedSame ? first.tag < second.tag : order == .orderedAscending
            }
        return Sections(system: system, popular: popular.map(\.tag), others: others.map(\.tag))
    }

    static func displayName(_ tag: String, in locale: Locale) -> String {
        locale.localizedString(forLanguageCode: tag) ?? tag
    }

    /// "1 model" / "9 models", localized.
    static func modelCountText(_ count: Int) -> String {
        count == 1 ? L10n.string("models.languages.modelCount.one", count) : L10n.string("models.languages.modelCount", count)
    }
}
