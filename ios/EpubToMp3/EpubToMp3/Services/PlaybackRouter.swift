import Foundation

/// What the playback layer should do with a single chapter at the
/// moment the user (or the reader's auto-advance) asks to play it.
///
/// - `audio(URL)`: the chapter has a usable MP3 — primary path.
/// - `speech(text:languageCode:)`: no usable MP3, but the chapter has
///   text on disk; route to `SpeechFallbackPlayer`.
/// - `skip`: neither audio nor text — nothing we can do.
enum PlaybackRoute: Equatable {
    case audio(URL)
    case speech(text: String, languageCode: String?)
    case skip
}

/// Pure decision unit that picks the right `PlaybackRoute` for a
/// chapter. Intentionally side-effect-free so unit tests can pin every
/// branch without standing up an `AVPlayer` or a real network/file
/// system. Slice 3 will plug a concrete `isAudioPlayable` probe.
enum PlaybackRouter {

    static func route(
        chapter: JobSnapshot.Chapter,
        baseURL: URL?,
        localAudioURL: URL? = nil,
        chapterText: String?,
        languageCode: String?,
        isAudioPlayable: (URL) -> Bool = { _ in true }
    ) -> PlaybackRoute {
        if let localAudioURL, isAudioPlayable(localAudioURL) {
            return .audio(localAudioURL)
        }
        if let url = resolvedAudioURL(rawDownloadUrl: chapter.downloadUrl,
                                       baseURL: baseURL),
           isAudioPlayable(url) {
            return .audio(url)
        }

        if let text = chapterText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return .speech(text: text, languageCode: languageCode)
        }

        return .skip
    }

    /// Resolve `rawDownloadUrl` into a usable `URL`. Returns `nil` for
    /// missing / empty / unparsable inputs. Absolute URLs are returned
    /// as-is; relative paths are anchored against `baseURL` when
    /// provided.
    static func resolvedAudioURL(
        rawDownloadUrl: String?,
        baseURL: URL?
    ) -> URL? {
        guard let raw = rawDownloadUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if let direct = URL(string: raw), direct.scheme != nil {
            return direct
        }

        guard let base = baseURL else {
            return URL(string: raw)
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}
