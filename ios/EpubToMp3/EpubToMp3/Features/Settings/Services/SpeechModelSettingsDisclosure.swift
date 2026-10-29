import Foundation

/// Presentation-only disclosure; selection and transfer ownership stay in Rust/client stores.
struct SpeechModelSettingsDisclosure {
    enum Row: Equatable {
        case primary, cellular, summary, model(Int?), secondary, onlineFallback, studyLanguage
    }
    private(set) var isExpanded = false

    mutating func toggle() { isExpanded.toggle() }

    func rows(modelCount: Int) -> [Row] {
        let models: [Row] = isExpanded
            ? (modelCount > 0 ? (0..<modelCount).map { .model($0) } : [.model(nil)]) : []
        return [.primary, .cellular, .summary] + models + [.secondary, .onlineFallback, .studyLanguage]
    }

    static func summary(state: SpeechModelLibraryViewState, primary: TtsSelection,
                        events: [String: SpeechModelInstallEvent]) -> String {
        var lines = [state.displayName(for: primary)]
        if let entry = state.entry(for: primary) { lines.append(state.status(for: entry)) }
        else if primary.engine == "piper" { lines.append(L10n.string("settings.modelState.notInspected")) }
        for entry in state.orderedEntries {
            guard let event = events[entry.identity.modelID], event.modelID == entry.identity.modelID,
                  event.stage != .completed else { continue }
            lines.append(state.displayName(for: entry) + ": " + state.installStatus(for: event))
        }
        return lines.joined(separator: "\n")
    }
}
