import Foundation
import WidgetKit
import ActivityKit

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

    // MARK: - Conversion progress (every 5 chapters)

    /// Update conversion progress in the App Group and reload ContinueReading
    /// timelines. Must be called every 5 completed chapters from the conversion
    /// job observer.
    ///
    /// - Parameters:
    ///   - bookTitle: display title of the book being converted
    ///   - chaptersDone: number of chapters successfully converted so far
    ///   - chaptersTotal: total chapters in the job
    ///   - currentChapterName: name of the chapter currently being synthesised
    static func updateConversionProgress(
        bookTitle: String,
        chaptersDone: Int,
        chaptersTotal: Int,
        currentChapterName: String? = nil
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(bookTitle, forKey: "widget.conversion.bookTitle")
        defaults.set(chaptersDone, forKey: "widget.conversion.chaptersDone")
        defaults.set(chaptersTotal, forKey: "widget.conversion.chaptersTotal")
        defaults.set(currentChapterName, forKey: "widget.conversion.currentChapterName")

        // Reload home-screen widgets so the conversion state is visible.
        WidgetCenter.shared.reloadAllTimelines()

        // Update the running Live Activity if one exists.
        guard #available(iOS 16.2, *) else { return }
        let state = ConversionActivityAttributes.ContentState(
            chaptersDone: chaptersDone,
            chaptersTotal: chaptersTotal,
            currentChapterName: currentChapterName
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(300))
        Task {
            for activity in Activity<ConversionActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    // MARK: - Live Activity management

    /// Start a Live Activity for a new conversion job. Safe to call on iOS < 16.2 —
    /// the guard exits silently.
    @discardableResult
    static func startConversionActivity(
        bookTitle: String,
        bookId: String,
        chaptersTotal: Int
    ) -> String? {
        guard #available(iOS 16.2, *) else { return nil }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }

        let attributes = ConversionActivityAttributes(
            bookTitle: bookTitle,
            bookId: bookId
        )
        let initialState = ConversionActivityAttributes.ContentState(
            chaptersDone: 0,
            chaptersTotal: chaptersTotal,
            currentChapterName: nil
        )
        let content = ActivityContent(
            state: initialState,
            staleDate: Date().addingTimeInterval(3600) // 1h — jobs rarely exceed this
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            return activity.id
        } catch {
            return nil
        }
    }

    /// End all conversion Live Activities for the given `bookId`.
    /// Pass `failed: true` to show a failure state before dismissal.
    /// Must be called explicitly when a job reaches done/failed/cancelled —
    /// never rely on `staleDate` for cleanup.
    static func endConversionActivity(bookId: String, failed: Bool = false) {
        guard #available(iOS 16.2, *) else { return }
        let finalState = ConversionActivityAttributes.ContentState(
            chaptersDone: 0,
            chaptersTotal: 0,
            currentChapterName: failed ? "Conversion failed" : "Done"
        )
        let content = ActivityContent(
            state: finalState,
            staleDate: Date().addingTimeInterval(5)
        )
        Task {
            for activity in Activity<ConversionActivityAttributes>.activities
            where activity.attributes.bookId == bookId {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4)))
            }
        }
    }

    // MARK: - Reload helpers

    static func reloadNowPlayingWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.legacy)
        WidgetCenter.shared.reloadTimelines(ofKind: "NowPlayingLockScreenWidget")
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
