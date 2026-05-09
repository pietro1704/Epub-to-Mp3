import Foundation

/// One book in the user's local library. Anchored on the EPUB file the
/// user picked from disk, NOT on a backend job — the app is primarily a
/// reader, not a conversion manager. The optional `jobId` records the
/// last conversion run for this book, so when the user taps "Save
/// offline" or resumes a partial export we can reattach the audio
/// without re-uploading.
///
/// Persisted as JSON inside `UserDefaults` under key
/// `"library.books.v1"` (see `LibraryStore`).
struct BookEntity: Codable, Identifiable, Hashable {
    /// Stable id derived from the EPUB file content hash; survives
    /// renames and moves of the bookmarked file.
    let id: String

    /// User-visible title. Pulled from EPUB metadata when the book is
    /// imported, with the filename as fallback.
    var title: String

    /// User-visible author. Best-effort from EPUB `dc:creator`.
    var author: String?

    /// macOS / iOS security-scoped bookmark to the original `.epub` on
    /// disk. Survives sandbox restarts. We resolve it lazily on every
    /// open and prompt the user to relocate if it has gone stale.
    var bookmark: Data

    /// Filename for display only — never used to access the file. Use
    /// `bookmark` for I/O.
    let displayFilename: String

    /// Imported timestamp.
    let addedAt: Date

    /// Last time the user opened the book (used for "Continue reading"
    /// section).
    var lastOpenedAt: Date?

    /// Resume point inside the book — chapter index + position seconds.
    /// Mirrors what `ResumeStore` keeps per (jobId, chapter).
    var lastChapterIndex: Int?
    var lastPositionSeconds: TimeInterval?

    /// Optional cached cover art. PNG/JPEG bytes, kept inline for now;
    /// large covers can be moved to a separate file cache later.
    var coverPNG: Data?

    /// If the user has run a conversion for this book, we keep the
    /// most recent jobId so we can reattach to the audio assets
    /// (downloadUrl[]) without re-uploading.
    var lastJobId: String?

    /// Whether the user opted in to caching the full audiobook on disk
    /// (the "Save offline" affordance). Controls whether the player
    /// uses streaming TTS or the cached MP3s.
    var cachedOffline: Bool = false

    enum LibraryStatus: String, Hashable, Codable {
        /// EPUB on disk, no audio yet — opening it streams TTS.
        case textOnly
        /// User pressed "Save offline" and a conversion is in flight.
        case caching
        /// Full audio cached locally — playback is offline.
        case offlineReady
    }

    var status: LibraryStatus {
        if cachedOffline { return .offlineReady }
        if lastJobId != nil { return .caching }
        return .textOnly
    }

    var resolvedTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? displayFilename : t
    }
}
