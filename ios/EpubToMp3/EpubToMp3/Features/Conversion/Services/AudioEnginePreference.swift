import Foundation

enum AudioEnginePreference: String, CaseIterable, Identifiable {
    case edge
    case piper

    var id: String { rawValue }
    var displayName: String { rawValue == "edge" ? "Edge" : "Piper" }

    static var supportedPreferences: [AudioEnginePreference] {
        [.edge]
    }
}
