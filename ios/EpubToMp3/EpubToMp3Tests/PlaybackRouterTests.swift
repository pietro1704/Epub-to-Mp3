import XCTest
@testable import EpubToMp3

/// Unit tests for `PlaybackRouter` — the pure decision unit that picks
/// between MP3 playback, accessibility-speech fallback, or skipping a
/// chapter altogether. Slice 2 in the SpeechFallback hand-off chain.
///
/// These tests pin only the decision logic. Wiring the router into
/// `AudioPlayer.play(...)` is slice 3, which will exercise the router
/// against real `JobSnapshot` flow and `FileManager` reachability.
final class PlaybackRouterTests: XCTestCase {

    // MARK: - Helpers

    private func chapter(
        index: Int = 0,
        downloadUrl: String? = nil
    ) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Chapter \(index)",
            status: "completed",
            downloadUrl: downloadUrl,
            chars: 5000,
            charsProcessed: 5000,
            progressRatio: 1.0,
            durationSeconds: 60,
            startedAt: nil,
            completedAt: nil
        )
    }

    // MARK: - Audio happy path

    func test_route_returnsAudio_whenDownloadUrlPresentAndPlayable() {
        let ch = chapter(downloadUrl: "https://example.com/ch01.mp3")
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: nil,
            chapterText: "fallback text we should NOT use",
            languageCode: "en-US",
            isAudioPlayable: { _ in true }
        )
        guard case let .audio(url) = route else {
            return XCTFail("expected .audio, got \(route)")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/ch01.mp3")
    }

    // MARK: - Speech fallback

    func test_route_returnsSpeech_whenDownloadUrlIsNil_andTextAvailable() {
        let ch = chapter(downloadUrl: nil)
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: nil,
            chapterText: "Once upon a time…",
            languageCode: "en-US"
        )
        XCTAssertEqual(route, .speech(text: "Once upon a time…", languageCode: "en-US"))
    }

    func test_route_returnsSpeech_whenDownloadUrlIsEmpty_andTextAvailable() {
        let ch = chapter(downloadUrl: "   ")
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: nil,
            chapterText: "Era uma vez…",
            languageCode: "pt-BR"
        )
        XCTAssertEqual(route, .speech(text: "Era uma vez…", languageCode: "pt-BR"))
    }

    func test_route_returnsSpeech_whenAudioNotPlayable_andTextAvailable() {
        // downloadUrl resolves to a URL, but the playability probe
        // reports it as unreachable (e.g. file missing on disk or 404
        // from the backend). Router must fall through to speech.
        let ch = chapter(downloadUrl: "https://example.com/missing.mp3")
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: nil,
            chapterText: "Hello world",
            languageCode: "en-US",
            isAudioPlayable: { _ in false }
        )
        XCTAssertEqual(route, .speech(text: "Hello world", languageCode: "en-US"))
    }

    func test_route_preservesNilLanguageCode_inSpeechBranch() {
        let ch = chapter(downloadUrl: nil)
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: nil,
            chapterText: "Sin idioma",
            languageCode: nil
        )
        XCTAssertEqual(route, .speech(text: "Sin idioma", languageCode: nil))
    }

    // MARK: - Skip

    func test_route_returnsSkip_whenNoUrlAndNoText() {
        let ch = chapter(downloadUrl: nil)
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: nil,
            chapterText: nil,
            languageCode: "en-US"
        )
        XCTAssertEqual(route, .skip)
    }

    func test_route_returnsSkip_whenTextIsWhitespaceOnly_andNoUrl() {
        let ch = chapter(downloadUrl: nil)
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: nil,
            chapterText: "   \n  \t  ",
            languageCode: "en-US"
        )
        XCTAssertEqual(route, .skip)
    }

    // MARK: - URL resolution

    func test_route_resolvesRelativeDownloadUrl_againstBaseURL() {
        let ch = chapter(downloadUrl: "/api/jobs/abc/chapters/0.mp3")
        let base = URL(string: "https://backend.local:8000")!
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: base,
            chapterText: nil,
            languageCode: nil,
            isAudioPlayable: { _ in true }
        )
        guard case let .audio(url) = route else {
            return XCTFail("expected .audio, got \(route)")
        }
        XCTAssertEqual(
            url.absoluteString,
            "https://backend.local:8000/api/jobs/abc/chapters/0.mp3"
        )
    }

    func test_route_keepsAbsoluteDownloadUrl_evenWithBaseURL() {
        // If `downloadUrl` already has a scheme, the baseURL must be
        // ignored — the chapter is hosted somewhere else (e.g. a CDN).
        let ch = chapter(downloadUrl: "https://cdn.example.com/ch01.mp3")
        let base = URL(string: "https://backend.local:8000")!
        let route = PlaybackRouter.route(
            chapter: ch,
            baseURL: base,
            chapterText: nil,
            languageCode: nil,
            isAudioPlayable: { _ in true }
        )
        guard case let .audio(url) = route else {
            return XCTFail("expected .audio, got \(route)")
        }
        XCTAssertEqual(url.absoluteString, "https://cdn.example.com/ch01.mp3")
    }
}
