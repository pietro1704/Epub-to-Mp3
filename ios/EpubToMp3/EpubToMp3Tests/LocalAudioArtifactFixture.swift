import Foundation
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// Seeds `LocalAudioArtifactStore` state the way the app finds it at launch:
/// a schema-1 manifest and canonical chapter files on disk, persisted through
/// the store's own `LocalAudioArtifactFiles` (atomic save, file policies and
/// change notification). The app has no production operation that creates
/// chapter artifacts other than `importLegacyAudio`; every other state already
/// exists on disk when the store reads it.
enum LocalAudioArtifactFixture {
    typealias ArtifactState = LocalAudioArtifactStore.ArtifactState
    typealias Retention = LocalAudioArtifactStore.Retention
    typealias ChapterArtifact = LocalAudioArtifactStore.ChapterArtifact
    typealias Manifest = LocalAudioArtifactStore.Manifest

    struct Chapter {
        let index: Int
        var title: String
        /// Defaults to `.available` with audio and `.pending` without it.
        var state: ArtifactState?
        var retention: Retention = .temporary
        /// Written to the canonical chapter file when present.
        var audio: Data?
        var playbackRetentionRequested: Bool?
        var retryCount = 0
        var lastError: String?
    }

    static func files(root: URL) -> LocalAudioArtifactFiles {
        LocalAudioArtifactFiles(root: root.standardizedFileURL, fileManager: .default)
    }

    /// Writes chapter files and merges the chapters into the book manifest,
    /// replacing only entries with the same index. Returns canonical file URLs.
    @discardableResult
    static func seed(
        root: URL, bookID: String, bookTitle: String? = nil, author: String? = nil,
        chapters: [Chapter]
    ) throws -> [Int: URL] {
        let files = files(root: root)
        try files.createDirectoryIfNeeded(files.chaptersDirectory(bookID: bookID))
        let now = Date()
        var urls: [Int: URL] = [:]
        var artifacts: [Int: ChapterArtifact] = [:]
        let existing = try files.loadManifest(bookID: bookID)
        for artifact in existing?.chapters ?? [] { artifacts[artifact.index] = artifact }
        for chapter in chapters {
            let relativePath = files.relativePath(for: chapter.index)
            let url = files.bookDirectory(bookID: bookID).appendingPathComponent(relativePath)
                .standardizedFileURL
            if let audio = chapter.audio { try audio.write(to: url) }
            urls[chapter.index] = url
            let state = chapter.state ?? (chapter.audio == nil ? .pending : .available)
            artifacts[chapter.index] = ChapterArtifact(
                index: chapter.index, title: chapter.title, state: state,
                retention: chapter.retention,
                playbackRetentionRequested: chapter.playbackRetentionRequested,
                relativePath: relativePath,
                byteCount: state == .available ? Int64(chapter.audio?.count ?? 0) : 0,
                retryCount: chapter.retryCount, lastError: chapter.lastError, updatedAt: now)
        }
        let manifest = Manifest(
            schemaVersion: LocalAudioArtifactStore.schemaVersion, bookID: bookID,
            bookTitle: bookTitle ?? existing?.bookTitle ?? bookID, author: author ?? existing?.author,
            chapters: artifacts.values.sorted { $0.index < $1.index }, updatedAt: now)
        try files.save(manifest)
        try files.repairFilePolicies(for: manifest)
        return urls
    }

    /// Reads the persisted manifest exactly as a relaunched store would.
    static func manifest(root: URL, bookID: String) throws -> Manifest? {
        try files(root: root).loadManifest(bookID: bookID)
    }

    static func artifact(root: URL, bookID: String, chapterIndex: Int) throws -> ChapterArtifact? {
        try manifest(root: root, bookID: bookID)?.chapters.first { $0.index == chapterIndex }
    }

    /// Persisted chapters that are protected downloads with audio on disk.
    static func downloadedIndices(root: URL, bookID: String) throws -> Set<Int> {
        let files = files(root: root)
        return Set((try manifest(root: root, bookID: bookID)?.chapters ?? []).filter {
            $0.retention == .downloaded && $0.state == .available
                && files.hasAudioFile(bookID: bookID, artifact: $0)
        }.map(\.index))
    }
}
