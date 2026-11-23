import Foundation

/// Read-only presentation cache of Rust snapshots for synchronous player callbacks.
final class SpeechModelPresentationStore: @unchecked Sendable {
    static let shared = SpeechModelPresentationStore()
    private let lock = NSLock()
    private var snapshot: SpeechModelSnapshot?
    private var explicitModelNames: [String: String] = [:]

    func update(_ snapshot: SpeechModelSnapshot) {
        lock.lock()
        self.snapshot = snapshot
        lock.unlock()
    }

    func rememberExplicitModels(in snapshot: SpeechModelSnapshot) {
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        lock.lock()
        defer { lock.unlock() }
        for entry in snapshot.entries where entry.presentation.quality == .low {
            explicitModelNames[entry.identity.modelID] = state.displayName(for: entry)
        }
    }

    func displayName(engine: String?, modelID: String?, voice: String?) -> String? {
        lock.lock()
        let state = SpeechModelLibraryViewState(snapshot: snapshot)
        let explicitName = modelID.flatMap { explicitModelNames[$0] }
        lock.unlock()
        if let explicitName { return explicitName }
        if let modelID, let entry = state.entries.first(where: { $0.identity.modelID == modelID }) {
            return state.displayName(for: entry)
        }
        if engine == TtsSelection.piperEngine { return TtsSelection.displayName(forEngine: TtsSelection.piperEngine) }
        if let voice, !voice.isEmpty {
            return voice.components(separatedBy: " (").first ?? voice
        }
        return engine.map { TtsSelection.displayName(forEngine: $0) ?? $0 }
    }

    func activeVoices(_ value: String, engine: String?) -> String {
        value.components(separatedBy: " + ").map {
            displayName(engine: engine, modelID: $0, voice: $0) ?? $0
        }.joined(separator: " + ")
    }
}
