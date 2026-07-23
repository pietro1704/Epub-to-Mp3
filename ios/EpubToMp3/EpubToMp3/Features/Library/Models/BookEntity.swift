import Foundation

/// Discriminator between the two natively supported book formats. The
/// Library opens both with the same picker / drop / share surface,
/// then routes to the right reader at open time.
enum BookFileType: String, Codable, Hashable, CaseIterable {
    case epub
    case pdf

    /// Best-effort classification by extension. Anything we cannot
    /// classify falls back to `.epub` because the EPUB reader is
    /// tolerant of non-zip inputs (returns an empty payload), whereas
    /// PDFKit hard-errors on non-PDF bytes.
    static func detect(from url: URL) -> BookFileType {
        switch url.pathExtension.lowercased() {
        case "pdf": return .pdf
        default:    return .epub
        }
    }
}

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

    /// Bookmark to the durable app-owned copy of the imported book. On
    /// macOS, legacy rows may initially point to the original external file
    /// and are migrated on their first successful open.
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

    /// Underlying file format. Defaults to `.epub` for backwards
    /// compatibility with rows persisted before the PDF support
    /// landed — the JSON decoder leaves missing fields at their
    /// default value.
    var fileType: BookFileType = .epub

    var tags: [String] = []

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

    // MARK: - Codable

    /// Custom decoder so old persisted entries (no `fileType` key)
    /// decode without crashing. The synthesised `Codable` impl treats
    /// every property as required — even with a default value — so we
    /// fall back to `.epub` ourselves and to the path-extension hint
    /// when the legacy entry has a `.pdf` `displayFilename`.
    enum CodingKeys: String, CodingKey {
        case id, title, author, bookmark, displayFilename, addedAt,
             lastOpenedAt, lastChapterIndex, lastPositionSeconds,
             coverPNG, lastJobId, cachedOffline, fileType, tags
    }

    init(
        id: String,
        title: String,
        author: String? = nil,
        bookmark: Data,
        displayFilename: String,
        addedAt: Date,
        lastOpenedAt: Date? = nil,
        lastChapterIndex: Int? = nil,
        lastPositionSeconds: TimeInterval? = nil,
        coverPNG: Data? = nil,
        lastJobId: String? = nil,
        cachedOffline: Bool = false,
        fileType: BookFileType = .epub,
        tags: [String] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.bookmark = bookmark
        self.displayFilename = displayFilename
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.lastChapterIndex = lastChapterIndex
        self.lastPositionSeconds = lastPositionSeconds
        self.coverPNG = coverPNG
        self.lastJobId = lastJobId
        self.cachedOffline = cachedOffline
        self.fileType = fileType
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
        self.bookmark = try c.decode(Data.self, forKey: .bookmark)
        self.displayFilename = try c.decode(String.self, forKey: .displayFilename)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        self.lastChapterIndex = try c.decodeIfPresent(Int.self, forKey: .lastChapterIndex)
        self.lastPositionSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .lastPositionSeconds)
        self.coverPNG = try c.decodeIfPresent(Data.self, forKey: .coverPNG)
        self.lastJobId = try c.decodeIfPresent(String.self, forKey: .lastJobId)
        self.cachedOffline = (try c.decodeIfPresent(Bool.self, forKey: .cachedOffline)) ?? false
        if let raw = try c.decodeIfPresent(BookFileType.self, forKey: .fileType) {
            self.fileType = raw
        } else {
            // Legacy entry — fall back to the filename hint so a
            // re-imported `.pdf` doesn't get stuck reading as EPUB.
            self.fileType = displayFilename.lowercased().hasSuffix(".pdf") ? .pdf : .epub
        }
        self.tags = (try c.decodeIfPresent([String].self, forKey: .tags)) ?? []
    }
}
