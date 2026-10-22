import Foundation

/// Errors the player can surface back to a native controller. Kept
/// minimal — anything more granular belongs in a category-specific
/// error type owned by the calling site.
///
/// `Identifiable` so controllers can identify a
/// new error fired DURING the previous alert's dismiss animation —
/// the `isPresented:` variant would silently drop it. Using the
/// raw value as id means setting `lastError = .x` twice in a row
/// is treated as the same alert (no re-flash); switching to a
/// different error re-presents.
enum PlaybackFailure: LocalizedError, Equatable, Identifiable {
    case noPlayableChapters
    case emptySegmentData
    case segmentWriteFailed
    case missingSnapshot

    var id: String {
        switch self {
        case .noPlayableChapters: return "noPlayableChapters"
        case .emptySegmentData: return "emptySegmentData"
        case .segmentWriteFailed: return "segmentWriteFailed"
        case .missingSnapshot: return "missingSnapshot"
        }
    }

    /// Surfaces user-actionable problems from the player without
    /// requiring the caller to wrap every method in `throws`. Set
    /// when a load / playback request fails in a way the user would
    /// notice silence about (e.g. `play(snapshot:)` invoked on an
    /// empty snapshot). Set back to `nil` by the consumer after it
    /// displays the toast / banner. Views observe via @Published.
    var errorDescription: String? {
        switch self {
        case .noPlayableChapters:
            return L10n.string("player.error.noPlayableChapters")
        case .emptySegmentData:
            return L10n.string("player.error.emptySegmentData")
        case .segmentWriteFailed:
            return L10n.string("player.error.segmentWriteFailed")
        case .missingSnapshot:
            return L10n.string("player.error.missingSnapshot")
        }
    }
}
