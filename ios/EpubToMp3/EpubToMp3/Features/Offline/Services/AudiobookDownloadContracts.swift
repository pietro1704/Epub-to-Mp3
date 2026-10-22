import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-chapter download state for `AudiobookDownloads`.
struct DownloadProgress: Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case queued
        case downloading
        case completed
        case failed
        case paused
        case cancelled
    }

    let jobId: String
    let chapterIndex: Int
    let totalChapters: Int
    let completedChapters: Int
    let bytesDownloaded: Int64
    let bytesExpected: Int64
    let state: State
    let lastError: String?
}

/// Persisted manifest for an audiobook on disk.
/// Lives at `Audiobooks/<jobId>/manifest.json` per the offline-cache-mobile
/// agent contract.
struct AudiobookManifest: Codable, Equatable, Sendable {
    struct ChapterEntry: Codable, Equatable, Sendable {
        let index: Int
        let title: String
        let mp3FileName: String
        let mp3Bytes: Int64
        let downloadedAt: Date
    }

    var jobId: String
    var bookTitle: String
    var chapters: [ChapterEntry]
    var totalBytes: Int64
    var completedAt: Date?
}
