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
        guard snapshot.target?.language == language,
              let current = snapshot.entries.first(where: {
                  $0.identity.provider == entry.identity.provider && $0.identity.modelID == entry.identity.modelID
                      && $0.identity.modelRevision == entry.identity.modelRevision
              }), current.installation.state == .installed,
              let selection = SpeechModelLibraryViewState(snapshot: snapshot).selection(for: current) else {
            throw SpeechModelInstallationError.incompatible(entry.identity.modelID)
        }
        return (selection, language)
    }
}
