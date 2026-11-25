import Foundation

/// Presentation-only summary of the Models row; selection and transfer ownership stay in Rust/client stores.
enum SpeechModelSettingsSummary {
    static func text(state: SpeechModelLibraryViewState, primary: TtsSelection,
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
