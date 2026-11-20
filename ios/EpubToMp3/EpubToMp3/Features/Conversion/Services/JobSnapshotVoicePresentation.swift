import Foundation

extension JobSnapshot {
    /// Present the resolved voice names; installed identifiers remain in diagnostic state.
    var activeVoiceDisplayName: String? {
        guard let voice, !voice.isEmpty else { return nil }
        return SpeechModelPresentationStore.shared.activeVoices(voice, engine: engine)
    }
}
