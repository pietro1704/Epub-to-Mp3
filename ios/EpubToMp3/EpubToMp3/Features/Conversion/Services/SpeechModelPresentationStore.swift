import Foundation

/// Read-only presentation cache of Rust snapshots for synchronous player callbacks.
final class SpeechModelPresentationStore: @unchecked Sendable {
    static let shared = SpeechModelPresentationStore()
    private let lock = NSLock()
    private var snapshot: SpeechModelSnapshot?

    func update(_ snapshot: SpeechModelSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func displayName(engine: String?, modelID: String?, voice: String?) -> String? {
        lock.lock()
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        lock.unlock()
        if let modelID, let entry = state.entries.first(where: { $0.identity.modelID == modelID }) {
            return state.displayName(for: entry)
        }
        if engine == "piper" { return "Piper" }
        if let voice, !voice.isEmpty {
            return voice.components(separatedBy: " (").first ?? voice
        }
        return engine.map { AudioEnginePreference(rawValue: $0)?.displayName ?? $0 }
    }

    func activeVoices(_ value: String, engine: String?) -> String {
        value.components(separatedBy: " + ").map {
            displayName(engine: engine, modelID: $0, voice: $0) ?? $0
        }.joined(separator: " + ")
    }
}
