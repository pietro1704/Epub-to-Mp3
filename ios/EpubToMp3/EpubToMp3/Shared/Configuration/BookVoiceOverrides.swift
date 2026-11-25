import Foundation

/// The voice the listener picked for one book in the reader. Rust decides whether it can still be used
/// (`book_voice`); the global and per-language choices are never changed by it.
struct BookVoiceOverrides {
    private static let key = "book.voiceOverrides.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func voice(bookID: String) -> TtsSelection? { stored[bookID] }

    func set(_ voice: TtsSelection?, bookID: String) {
        var voices = stored
        voices[bookID] = voice
        do { defaults.set(try JSONEncoder().encode(voices), forKey: Self.key) }
        catch { _ = AppErrorReporter.message(error, context: "Save the book voice") }
    }

    private var stored: [String: TtsSelection] {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: TtsSelection].self, from: $0) } ?? [:]
    }
}
