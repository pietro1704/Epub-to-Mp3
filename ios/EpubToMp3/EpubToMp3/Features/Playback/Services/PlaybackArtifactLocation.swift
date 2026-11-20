import Foundation

/// Resolves the audio file a chapter plays from.
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

    /// The chapter's own local file plays when it is usable. A copy kept by the
    /// previous `Audiobooks/<jobId>` layout stands in when the chapter is remote
    /// or its own file is missing or cannot be prepared.
    static func resolve(forDownloadPath path: String?, jobId: String? = nil, chapterIndex: Int? = nil, backendBaseURL: URL?) -> URL? {
        let own = Self.playbackURL(forDownloadPath: path, backendBaseURL: backendBaseURL)
        if let own, own.isFileURL, FileManager.default.fileExists(atPath: own.path),
           let ready = prepared(own) {
            return ready
        }
        if let jobId, let chapterIndex,
           let kept = AudiobookDownloadStorage.localAudioURL(jobId: jobId, chapterIndex: chapterIndex),
           let ready = prepared(kept) {
            return ready
        }
        guard let own, !own.isFileURL else { return nil }
        return own
    }

    /// Whether playback would use this local file as it is: it exists and is
    /// prepared. The legacy migration asks this before it removes a kept copy.
    static func isPlayable(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path) && prepared(url) != nil
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
