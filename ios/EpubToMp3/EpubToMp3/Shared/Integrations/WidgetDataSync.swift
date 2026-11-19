import Foundation
import WidgetKit

/// Writes enriched metadata to the shared App Group UserDefaults so
/// WidgetKit extensions can render Now Playing, Continue Reading, and
/// Library widgets without IPC. Call sites: `PlaybackBindingStore`,
/// `BookOpenScreenController`, `MainReaderScreenController`, `AudioPlayer`.
///
/// All keys are prefixed `widget.` to avoid collisions with the main
/// app's UserDefaults layout. The `library.books.v1` key is shared
/// directly by `LibraryStore` (already writes to the App Group suite).
enum WidgetDataSync {

    static let appGroupID = LibraryStore.appGroupID

    // MARK: - Shared key constants

    /// Keys must match `EpubToMp3Widget.swift` in the widget extension.
    private enum Keys {
        static let nowPlayingBookId = "currentlyPlayingBookId"
        static let nowPlayingChapterName = "widget.nowPlayingChapterName"
        static let nowPlayingAuthor = "widget.nowPlayingAuthor"
        static let nowPlayingProgress = "widget.nowPlayingProgress"
        static let nowPlayingIsPlaying = "widget.nowPlayingIsPlaying"
        static let nowPlayingPositionSeconds = "widget.nowPlayingPositionSeconds"
        static let nowPlayingDurationSeconds = "widget.nowPlayingDurationSeconds"
        static let nowPlayingChapterRemainingSeconds = "widget.nowPlayingChapterRemainingSeconds"
        static let nowPlayingBookRemainingSeconds = "widget.nowPlayingBookRemainingSeconds"
        static let nowPlayingTotalChapters = "widget.nowPlayingTotalChapters"
    }

    // MARK: - Widget kind identifiers

    private enum WidgetKind {
        static let legacy = "EpubToMp3Widget"
        static let nowPlaying = "NowPlayingWidget"
        static let library = "LibraryWidget"
    }

    // MARK: - Now Playing

    /// Update the now-playing metadata visible to the widget extension.
    /// Call this when playback state changes (play/pause, chapter advance,
    /// progress tick).
    static func updateNowPlaying(
        bookId: String?,
        chapterName: String? = nil,
        author: String? = nil,
        progress: Double = 0,
        isPlaying: Bool = false,
        positionSeconds: Double = 0,
        durationSeconds: Double = 0,
        chapterRemainingSeconds: Double = 0,
        bookRemainingSeconds: Double = 0,
        totalChapters: Int? = nil,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupID),
        reloadWidgets: () -> Void = WidgetDataSync.reloadNowPlayingWidgets
    ) {
        guard let defaults else { return }

        if let bookId, !bookId.isEmpty {
            defaults.set(bookId, forKey: Keys.nowPlayingBookId)
            defaults.set(chapterName, forKey: Keys.nowPlayingChapterName)
            defaults.set(author, forKey: Keys.nowPlayingAuthor)
            defaults.set(progress, forKey: Keys.nowPlayingProgress)
            defaults.set(isPlaying, forKey: Keys.nowPlayingIsPlaying)
            defaults.set(positionSeconds, forKey: Keys.nowPlayingPositionSeconds)
            defaults.set(durationSeconds, forKey: Keys.nowPlayingDurationSeconds)
            defaults.set(chapterRemainingSeconds, forKey: Keys.nowPlayingChapterRemainingSeconds)
            defaults.set(bookRemainingSeconds, forKey: Keys.nowPlayingBookRemainingSeconds)
            if let totalChapters {
                defaults.set(totalChapters, forKey: Keys.nowPlayingTotalChapters)
            } else {
                defaults.removeObject(forKey: Keys.nowPlayingTotalChapters)
            }
        } else {
            defaults.removeObject(forKey: Keys.nowPlayingBookId)
            defaults.removeObject(forKey: Keys.nowPlayingChapterName)
            defaults.removeObject(forKey: Keys.nowPlayingAuthor)
            defaults.removeObject(forKey: Keys.nowPlayingProgress)
            defaults.removeObject(forKey: Keys.nowPlayingIsPlaying)
            defaults.removeObject(forKey: Keys.nowPlayingPositionSeconds)
            defaults.removeObject(forKey: Keys.nowPlayingDurationSeconds)
            defaults.removeObject(forKey: Keys.nowPlayingChapterRemainingSeconds)
            defaults.removeObject(forKey: Keys.nowPlayingBookRemainingSeconds)
            defaults.removeObject(forKey: Keys.nowPlayingTotalChapters)
        }

        reloadWidgets()
    }

    /// Update playback progress (0.0–1.0). Debounced by the caller;
    /// we just write and reload.
    static func updateNowPlayingProgress(_ progress: Double) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(progress, forKey: Keys.nowPlayingProgress)
        // Skip reload for progress-only updates — the widget refreshes
        // on its own timeline. Avoids excessive reload calls during
        // playback.
    }

    static func updateNowPlayingTiming(
        positionSeconds: Double,
        durationSeconds: Double,
        chapterRemainingSeconds: Double,
        bookRemainingSeconds: Double,
        totalChapters: Int?,
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)
    ) {
        guard let defaults else { return }
        defaults.set(positionSeconds, forKey: Keys.nowPlayingPositionSeconds)
        defaults.set(durationSeconds, forKey: Keys.nowPlayingDurationSeconds)
        defaults.set(chapterRemainingSeconds, forKey: Keys.nowPlayingChapterRemainingSeconds)
        defaults.set(bookRemainingSeconds, forKey: Keys.nowPlayingBookRemainingSeconds)
        if let totalChapters {
            defaults.set(totalChapters, forKey: Keys.nowPlayingTotalChapters)
        } else {
            defaults.removeObject(forKey: Keys.nowPlayingTotalChapters)
        }
    }

    // MARK: - Library

    /// Reload the library widget timelines. Called by `LibraryStore`
    /// after `persist()` so the widget picks up new/removed books.
    static func reloadLibraryWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.library)
    }

    // MARK: - Reload helpers

    static func reloadNowPlayingWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.legacy)
        WidgetCenter.shared.reloadTimelines(ofKind: "NowPlayingLockScreenWidget")
    }

    /// Reload all widget timelines at once. Call on major state changes
    /// (app foreground, library import).
    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
