import Foundation

/// An audition captures the installed model's own language and revision. It
/// never changes the language used to select narration for the current book.
struct SpeechModelAudition {
    let language: String
    private let entry: SpeechModelSnapshot.Entry

    init(entry: SpeechModelSnapshot.Entry) throws {
        guard let language = entry.languageEvidence.exactTags.first?.tag else {
            throw SpeechModelInstallationError.incompatible(entry.identity.modelID)
        }
        self.language = language
        self.entry = entry
    }

    func resolve(_ snapshot: SpeechModelSnapshot) throws -> (selection: TtsSelection, language: String) {
        let selection = try Self.selection(for: entry, language: language, in: snapshot)
        return (selection, language)
    }

    static func selection(
        for entry: SpeechModelSnapshot.Entry, language: String, in snapshot: SpeechModelSnapshot
    ) throws -> TtsSelection {
        guard snapshot.target?.language == language,
              let current = snapshot.entries.first(where: { $0.identity == entry.identity }),
              current.compatibility.compatible, current.installation.state == .installed,
              current.readiness.state == .ready,
              let selection = SpeechModelLibraryViewState(snapshot: snapshot).selection(for: current) else {
            throw SpeechModelInstallationError.incompatible(entry.identity.modelID)
        }
        return selection
    }
}
