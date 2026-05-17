import Foundation
import WidgetKit

/// Writes enriched metadata to the shared App Group UserDefaults so
/// WidgetKit extensions can render Now Playing, Continue Reading, and
/// Library widgets without IPC. Call sites: `NowPlayingView`,
/// `BookOpenView`, `MainReaderView`, `AudioPlayer`.
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
        static let nowPlayingProgress = "widget.nowPlayingProgress"
        static let nowPlayingIsPlaying = "widget.nowPlayingIsPlaying"
        static let lastReadBookId = "widget.lastReadBookId"
        static let lastReadChapterIndex = "widget.lastReadChapterIndex"
        static let lastReadTotalChapters = "widget.lastReadTotalChapters"
    }

    // MARK: - Widget kind identifiers

    private enum WidgetKind {
        static let legacy = "EpubToMp3Widget"
        static let nowPlaying = "NowPlayingWidget"
        static let continueReading = "ContinueReadingWidget"
        static let library = "LibraryWidget"
    }

    // MARK: - Now Playing

    /// Update the now-playing metadata visible to the widget extension.
    /// Call this when playback state changes (play/pause, chapter advance,
    /// progress tick).
    static func updateNowPlaying(
        bookId: String?,
        chapterName: String? = nil,
        progress: Double = 0,
        isPlaying: Bool = false
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        if let bookId, !bookId.isEmpty {
            defaults.set(bookId, forKey: Keys.nowPlayingBookId)
            defaults.set(chapterName, forKey: Keys.nowPlayingChapterName)
            defaults.set(progress, forKey: Keys.nowPlayingProgress)
            defaults.set(isPlaying, forKey: Keys.nowPlayingIsPlaying)
        } else {
            defaults.removeObject(forKey: Keys.nowPlayingBookId)
            defaults.removeObject(forKey: Keys.nowPlayingChapterName)
            defaults.removeObject(forKey: Keys.nowPlayingProgress)
            defaults.removeObject(forKey: Keys.nowPlayingIsPlaying)
        }

        reloadNowPlayingWidgets()
    }

    /// Update only the isPlaying flag without touching other fields.
    /// Lightweight — called on every play/pause toggle.
    static func updateIsPlaying(_ isPlaying: Bool) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(isPlaying, forKey: Keys.nowPlayingIsPlaying)
        reloadNowPlayingWidgets()
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

    // MARK: - Continue Reading

    /// Update the last-read book metadata. Call this when the user opens
    /// or navigates within a book in the reader.
    static func updateLastRead(
        bookId: String,
        chapterIndex: Int,
        totalChapters: Int? = nil
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(bookId, forKey: Keys.lastReadBookId)
        defaults.set(chapterIndex, forKey: Keys.lastReadChapterIndex)
        if let total = totalChapters {
            defaults.set(total, forKey: Keys.lastReadTotalChapters)
        }
        reloadContinueReadingWidgets()
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
    }

    static func reloadContinueReadingWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.continueReading)
    }

    /// Reload all widget timelines at once. Call on major state changes
    /// (app foreground, library import).
    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
