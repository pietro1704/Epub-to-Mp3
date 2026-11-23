import Foundation

/// Presentation model of the Models screen: models grouped by book language,
/// split into local and online kinds, one choice per language. It never touches
/// persisted identity: a row only knows which `TtsSelection` it stands for.
struct ModelsByLanguageViewState: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case local, online }

    enum Availability: Sendable, Equatable {
        /// Installed and selectable now.
        case ready
        /// Not downloaded yet: dimmed, and a tap starts the download.
        case downloadable(bytes: UInt64?)
        /// Online voice while the online consent is off: dimmed.
        case needsConsent
        /// Incompatible or not installable on this device: dimmed, nothing to do.
        case unavailable
    }

    struct Row: Sendable, Equatable, Identifiable {
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        let selection: TtsSelection
        let availability: Availability
        let isChosen: Bool
        /// Piper Low voices: never automatic, a suggestion or a fallback; only an explicit per-language choice.
        var isExplicitOnly: Bool { kind == .local && detail == "low" }
        /// The installed system voice is always available: never dimmed.
        var isDimmed: Bool {
            switch availability {
            case .ready: return false
            case .downloadable, .needsConsent, .unavailable: return true
            }
        }
    }

    struct Section: Sendable, Equatable, Identifiable {
        let language: String
        let rows: [Row]
        var id: String { language }
        var local: [Row] { rows.filter { $0.kind == .local } }
        var online: [Row] { rows.filter { $0.kind == .online } }
        var chosen: Row? { rows.first(where: \.isChosen) }
    }

    struct Language: Sendable {
        let tag: String
        let snapshot: SpeechModelSnapshot
    }

    let sections: [Section]

    /// `languages` are the catalog's base languages in display order, each with
    /// its Rust snapshot; `systemVoiceLanguages` are the languages that have an
    /// installed system voice.
    static func make(
        languages: [Language],
        choices: [String: TtsSelection],
        allowOnlineFallback: Bool,
        systemVoiceLanguages: Set<String>,
        showLowQuality: Bool = false
    ) -> Self {
        let systemLanguages = Set(systemVoiceLanguages.map(SpeechPreferences.languageKey))
        let sections = languages.map { language -> Section in
            let key = SpeechPreferences.languageKey(language.tag)
            let chosen = choices[key]
            // A language snapshot lists the whole catalog with per-target compatibility:
            // keep only the models that are about this language.
            let entries = language.snapshot.entries
                .filter { entry in entry.languageEvidence.routingTags.contains { SpeechPreferences.languageKey($0) == key } }
                // The "piper-default" alias is a catalog placeholder, not a voice.
                .filter { $0.identity.modelID != "piper-default" }
            var rows = entries.compactMap { row(for: $0, chosen: chosen, allowOnlineFallback: allowOnlineFallback) }
                // Low voices appear only on request; hiding never drops the voice the listener chose.
                .filter { showLowQuality || !$0.isExplicitOnly || $0.isChosen }
            if systemLanguages.contains(key) {
                let selection = TtsSelection.systemDefault
                rows.append(Row(
                    id: "system:\(key)", kind: .local,
                    title: L10n.string(key == "pt" ? "settings.systemTts" : "models.systemVoice"), detail: "",
                    selection: selection, availability: .ready,
                    isChosen: chosen?.representsSameRequest(as: selection) == true))
            }
            // Edge is an online engine, not a catalog model: it is offered for every language
            // (its voice is chosen by Rust per language), dimmed until the online consent is on.
            if !entries.contains(where: { $0.identity.provider == TtsSelection.edgeEngine }) {
                let selection = TtsSelection.edgeDefault
                rows.append(Row(
                    id: "edge:\(key)", kind: .online, title: TtsSelection.displayName(forEngine: TtsSelection.edgeEngine) ?? "Edge",
                    detail: "", selection: selection,
                    availability: allowOnlineFallback ? .ready : .needsConsent,
                    isChosen: chosen?.representsSameRequest(as: selection) == true))
            }
            return Section(language: key, rows: rows.sorted(by: order))
        }
        // Languages with a ready local model come first (catalog order otherwise), so
        // what the user can already read with is at the top of a long list.
        func hasReadyLocal(_ section: Section) -> Bool {
            section.rows.contains { $0.kind == .local && $0.availability == .ready && $0.selection.engine == TtsSelection.piperEngine }
        }
        return Self(sections: sections.filter(hasReadyLocal) + sections.filter { !hasReadyLocal($0) })
    }

    private static func row(
        for entry: SpeechModelSnapshot.Entry, chosen: TtsSelection?, allowOnlineFallback: Bool
    ) -> Row? {
        let provider = entry.identity.provider
        guard provider != "system" else { return nil }
        let selection = provider == TtsSelection.edgeEngine
            ? TtsSelection.edgeDefault
            : TtsSelection(engine: provider, modelID: entry.identity.modelID, voice: nil)
        let kind: Kind = provider == TtsSelection.edgeEngine ? .online : .local
        let availability: Availability
        if kind == .online {
            availability = !entry.compatibility.compatible ? .unavailable
                : (allowOnlineFallback ? .ready : .needsConsent)
        } else if entry.installation.state == .installed && usableWithoutProbe(entry) {
            availability = .ready
        } else if entry.installation.state != .installed && entry.compatibility.compatible
                    && entry.distribution.installable {
            availability = .downloadable(bytes: entry.distribution.downloadBytes)
        } else {
            availability = .unavailable
        }
        return Row(
            id: "\(provider):\(entry.identity.modelID)", kind: kind,
            title: entry.presentation.modelName, detail: entry.presentation.quality.rawValue,
            selection: selection, availability: availability,
            isChosen: chosen?.representsSameRequest(as: selection) == true)
    }

    /// Installed and compatible; the runtime probe is not run for the listing, so
    /// "readiness not inspected" is the only reason that does not block a choice.
    private static func usableWithoutProbe(_ entry: SpeechModelSnapshot.Entry) -> Bool {
        entry.selection.selectable
            || (entry.compatibility.compatible
                && entry.selection.reasons.allSatisfy { $0 == "readiness_not_inspected" })
    }

    /// Local before online, then installed before the rest, then best quality, then name.
    private static func order(_ first: Row, _ second: Row) -> Bool {
        func rank(_ row: Row) -> (Int, Int, Int) {
            let kind = row.kind == .local ? 0 : 1
            let ready = row.isDimmed ? 1 : 0
            let quality = ["high": 0, "medium": 1, "low": 2][row.detail] ?? 3
            return (kind, ready, quality)
        }
        let a = rank(first), b = rank(second)
        return a != b ? a < b : first.title < second.title
    }
}
