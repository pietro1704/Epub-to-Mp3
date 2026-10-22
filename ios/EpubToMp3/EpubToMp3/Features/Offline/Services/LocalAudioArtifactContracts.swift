import Foundation

extension LocalAudioArtifactStore {
    enum ArtifactState: String, Codable, Equatable, Sendable {
        case pending
        case generating
        case waitingForWiFi
        case available
        case failed
    }

    enum Retention: String, Codable, Equatable, Sendable {
        case temporary
        case downloaded
    }

    struct ChapterSeed: Codable, Equatable, Sendable {
        let index: Int
        let title: String
    }

    struct ChapterArtifact: Codable, Equatable, Sendable {
        let index: Int
        var title: String
        var state: ArtifactState
        var retention: Retention
        var playbackRetentionRequested: Bool? = nil
        let relativePath: String
        var byteCount: Int64
        var retryCount: Int
        var lastError: String?
        var updatedAt: Date
    }

    struct Manifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let bookID: String
        var bookTitle: String
        var author: String?
        var chapters: [ChapterArtifact]
        var updatedAt: Date
    }

    struct StorageUsage: Equatable, Sendable {
        let temporaryBytes: Int64
        let downloadedBytes: Int64

        var totalBytes: Int64 { temporaryBytes + downloadedBytes }
    }

    /// A compact projection for Settings. The manifest remains the durable
    /// source of truth; this only exposes books that contain protected audio.
    struct DownloadedBook: Equatable, Sendable {
        let bookID: String
        let title: String
        let author: String?
        let chapterCount: Int
        let byteCount: Int64
    }

    enum StoreError: LocalizedError, Equatable {
        case unknownBook(String)
        case unknownChapter(bookID: String, chapterIndex: Int)
        case missingAudioFile(URL)
        case invalidAudioFile(URL)

        var errorDescription: String? {
            switch self {
            case .unknownBook(let bookID):
                return "No local audio manifest exists for \(bookID)."
            case .unknownChapter(let bookID, let chapterIndex):
                return "No local audio chapter \(chapterIndex) exists for \(bookID)."
            case .missingAudioFile(let url):
                return "The local audio file is missing at \(url.path)."
            case .invalidAudioFile(let url):
                return "The local audio file is empty at \(url.path)."
            }
        }
    }

}
