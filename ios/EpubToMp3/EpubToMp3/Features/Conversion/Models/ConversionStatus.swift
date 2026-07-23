import Foundation

/// Live status of the in-progress TTS conversion for a single book session.
///
/// Owned by `AudioPlayer` and written from both the embedded-TTS path
/// (`BookOpenView.bootstrapEmbedded`) and the backend-SSE path
/// (`BookOpenView.subscribeToStream`). `InstantReaderView` observes it
/// via `ConversionStatusSheet`.
///
/// Thread-safety: all mutating methods are `@MainActor` — same isolation
/// as the owning `AudioPlayer`.
@MainActor
final class ConversionStatus: ObservableObject {

    // MARK: - Event model

    enum EventKind: String {
        case chunkStart      = "chunk_start"
        case chunkComplete   = "chunk_complete"
        case chapterComplete = "chapter_complete"
        case error           = "error"
        case info            = "info"

        var systemImage: String {
            switch self {
            case .chunkStart:      return "waveform"
            case .chunkComplete:   return "checkmark.circle"
            case .chapterComplete: return "checkmark.circle.fill"
            case .error:           return "exclamationmark.triangle.fill"
            case .info:            return "info.circle"
            }
        }
    }

    struct ConversionEvent: Identifiable {
        let id: UUID = UUID()
        let timestamp: Date
        let kind: EventKind
        let message: String
    }

    // MARK: - Published state

    /// Ring buffer of the most recent N events. Written from
    /// `record(_:_:)`; UI auto-scrolls to the last entry.
    @Published private(set) var events: [ConversionEvent] = []

    /// Human-readable title of the chapter currently being synthesised.
    @Published private(set) var currentChapterName: String? = nil

    /// Zero-based index of the chapter currently being synthesised.
    @Published private(set) var currentChapterIndex: Int? = nil

    /// Last error message, if any. Shown in the sheet with a Retry button.
    @Published private(set) var lastError: String? = nil

    /// Wall-clock moment when the current conversion started.
    @Published private(set) var startedAt: Date? = nil

    // MARK: - Constants

    private static let maxEvents = 50

    // MARK: - Public API

    /// Mark the start of a new conversion session. Resets all state.
    func beginSession() {
        events.removeAll()
        currentChapterName = nil
        currentChapterIndex = nil
        lastError = nil
        startedAt = Date()
    }

    /// Reset all state when the conversion finishes or is cancelled.
    func endSession() {
        startedAt = nil
    }

    /// Set the currently-active chapter by index and display name.
    func setCurrentChapter(index: Int, name: String) {
        currentChapterIndex = index
        currentChapterName = name
    }

    /// Append an event. Trims the ring buffer to `maxEvents`.
    func record(_ kind: EventKind, _ message: String) {
        let event = ConversionEvent(timestamp: Date(), kind: kind, message: message)
        events.append(event)
        if events.count > ConversionStatus.maxEvents {
            events.removeFirst(events.count - ConversionStatus.maxEvents)
        }
        if kind == .error {
            lastError = message
        }
    }

    /// Clear the last error, e.g. after a successful retry.
    func clearError() {
        lastError = nil
    }

    // MARK: - Derived

    /// Elapsed time since the session started, or `nil` when idle.
    var elapsedSeconds: TimeInterval? {
        guard let start = startedAt else { return nil }
        return Date().timeIntervalSince(start)
    }
}
