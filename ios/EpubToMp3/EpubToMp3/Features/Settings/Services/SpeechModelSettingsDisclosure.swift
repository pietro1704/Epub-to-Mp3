import Foundation

/// Presentation-only disclosure; selection and transfer ownership stay in Rust/client stores.
struct SpeechModelSettingsDisclosure {
    enum Row: Equatable {
        case primary, summary, model(Int?), secondary, automaticSystemFallback, onlineFallback, studyLanguage
    }
    private(set) var isExpanded = false

    mutating func toggle() { isExpanded.toggle() }

    func rows(modelCount: Int) -> [Row] {
        let models: [Row] = isExpanded
            ? (modelCount > 0 ? (0..<modelCount).map { .model($0) } : [.model(nil)]) : []
        return [.primary, .summary] + models + [.secondary, .automaticSystemFallback, .onlineFallback, .studyLanguage]
    }

    static func summary(state: SpeechModelLibraryViewState, primary: TtsSelection,
                        events: [String: SpeechModelInstallEvent]) -> String {
        var lines = [state.displayName(for: primary)]
        if let entry = state.entry(for: primary) { lines.append(state.status(for: entry)) }
        else if primary.isPiper { lines.append(L10n.string("settings.modelState.notInspected")) }
        for entry in state.orderedEntries {
            guard let event = events[entry.identity.modelID], event.modelID == entry.identity.modelID,
                  event.stage != .completed else { continue }
            lines.append(state.displayName(for: entry) + ": " + state.installStatus(for: event))
        }
        return lines.joined(separator: "\n")
    }
}

/// One section per declared language set; multilingual models appear exactly once.
struct SpeechModelLanguageSection {
    let languages: [String]
    let entries: [SpeechModelSnapshot.Entry]

    static func sections(state: SpeechModelLibraryViewState) -> [Self] {
        let groups = Dictionary(grouping: state.orderedEntries) { entry in
            let exact = entry.languageEvidence.exactTags.map(\.tag)
            return Array(Set((exact.isEmpty ? entry.languageEvidence.routingTags : exact)
                .map { $0.replacingOccurrences(of: "_", with: "-") })).sorted()
        }
        return groups.keys.sorted { $0.joined(separator: ",") < $1.joined(separator: ",") }
            .map { Self(languages: $0, entries: groups[$0] ?? []) }
    }

    func title(state: SpeechModelLibraryViewState) -> String {
        languages.isEmpty ? L10n.string("settings.modelLanguage.routingOnly")
            : languages.map { state.languageTitle($0) }.joined(separator: " · ")
    }
}
