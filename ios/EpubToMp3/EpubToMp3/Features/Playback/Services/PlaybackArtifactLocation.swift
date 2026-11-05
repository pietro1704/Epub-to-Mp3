import Foundation

/// Resolves local retained artifacts before compatibility download locations.
enum PlaybackArtifactLocation {
    /// Resolve a remote API path or local cached path to an audio URL.
    /// Backend paths must remain network URLs — treating `/api/...` as a
    /// filesystem path makes completed remote chapters silently unplayable.
    nonisolated static func playbackURL(forDownloadPath path: String?, backendBaseURL: URL?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute
        }
        if path == "/api" || path.hasPrefix("/api/") {
            return backendBaseURL.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return backendBaseURL.flatMap { URL(string: path, relativeTo: $0)?.absoluteURL }
    }

    static func resolve(forDownloadPath path: String?, jobId: String? = nil, chapterIndex: Int? = nil, backendBaseURL: URL?) -> URL? {
        if let jobId, let chapterIndex,
           let local = AudiobookDownloadStorage.localAudioURL(jobId: jobId, chapterIndex: chapterIndex) {
            return prepared(local)
        }
        return Self.playbackURL(forDownloadPath: path, backendBaseURL: backendBaseURL).flatMap(prepared)
    }

    private static func prepared(_ url: URL) -> URL? {
        guard url.isFileURL else { return url }
        do {
            try ConverterFFIAdapter().prepareCompletedAudio(at: url)
            return url
        } catch {
            return nil
        }
    }

}
