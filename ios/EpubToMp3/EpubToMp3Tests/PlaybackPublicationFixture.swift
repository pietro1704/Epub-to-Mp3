#if canImport(AVFoundation) && canImport(MediaPlayer)
import Foundation
import MediaPlayer
import XCTest
@testable import EpubToMp3

/// Isolates native publication and resume persistence for playback runtime tests.
@MainActor
final class PlaybackPublicationFixture {
    private static let standardKeys = [AudioPlayer.currentBookIDDefaultsKey,
        AudioPlayer.currentChapterIndexDefaultsKey, ReaderSessionState.currentlyReadingBookIDKey,
        AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
        AudioPlayer.readerCurrentSentenceIdDefaultsKey]
    private static let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName",
        "widget.nowPlayingAuthor", "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying",
        "widget.nowPlayingPositionSeconds", "widget.nowPlayingDurationSeconds",
        "widget.nowPlayingChapterRemainingSeconds", "widget.nowPlayingBookRemainingSeconds",
        "widget.nowPlayingTotalChapters"]
    private let suite = "PlaybackPublicationFixture-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let standardValues: [Any?]
    private let widget: UserDefaults?
    private let widgetValues: [Any?]
    private let nowPlaying: [String: Any]?
    let resumeStore: ResumeStore

    init() throws {
        let privateDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults = privateDefaults
        resumeStore = ResumeStore(storage: UserDefaultsResumeStorage(defaults: privateDefaults))
        standardValues = Self.standardKeys.map { UserDefaults.standard.object(forKey: $0) }
        let group = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        widget = group
        widgetValues = Self.widgetKeys.map { group?.object(forKey: $0) }
        nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
        UserDefaults.standard.set(suite, forKey: AudioPlayer.currentBookIDDefaultsKey)
        UserDefaults.standard.set(suite, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        // Empty identity prevents publication from targeting a real widget book.
        group?.set("", forKey: "currentlyPlayingBookId")
    }

    func restore(afterStopping player: AudioPlayer?) {
        player?.stop()
        for (key, value) in zip(Self.standardKeys, standardValues) {
            UserDefaults.standard.set(value, forKey: key)
        }
        for (key, value) in zip(Self.widgetKeys, widgetValues) { widget?.set(value, forKey: key) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
        defaults.removePersistentDomain(forName: suite)
    }
}
#endif
