import Foundation
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

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
        static let lastReadBookId = "widget.lastReadBookId"
        static let lastReadChapterIndex = "widget.lastReadChapterIndex"
        static let lastReadTotalChapters = "widget.lastReadTotalChapters"
        static let lastReadChapterLabel = "widget.lastReadChapterLabel"
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
        author: String? = nil,
        progress: Double = 0,
        isPlaying: Bool = false,
        positionSeconds: Double = 0,
        durationSeconds: Double = 0,
        chapterRemainingSeconds: Double = 0,
        bookRemainingSeconds: Double = 0,
        totalChapters: Int? = nil
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

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
            if let totalChapters { defaults.set(totalChapters, forKey: Keys.nowPlayingTotalChapters) }
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

    static func updateNowPlayingTiming(
        positionSeconds: Double,
        durationSeconds: Double,
        chapterRemainingSeconds: Double,
        bookRemainingSeconds: Double,
        totalChapters: Int?
    ) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(positionSeconds, forKey: Keys.nowPlayingPositionSeconds)
        defaults.set(durationSeconds, forKey: Keys.nowPlayingDurationSeconds)
        defaults.set(chapterRemainingSeconds, forKey: Keys.nowPlayingChapterRemainingSeconds)
        defaults.set(bookRemainingSeconds, forKey: Keys.nowPlayingBookRemainingSeconds)
        if let totalChapters { defaults.set(totalChapters, forKey: Keys.nowPlayingTotalChapters) }
    }

    // MARK: - Continue Reading

    /// Update the last-read book metadata. Call this when the user opens
    /// or navigates within a book in the reader.
    ///
    /// Debounced 800 ms: chapter swaps during fast pagination would
    /// otherwise fire `reloadContinueReadingWidgets()` (cross-process
    /// `WidgetCenter` IPC, 10-30 ms on cold widgetkitd) on every
    /// page-boundary cross. The 3 UserDefaults writes also batch into
    /// one trailing-edge flush.
    static func updateLastRead(
        bookId: String,
        chapterIndex: Int,
        totalChapters: Int? = nil
    ) {
        // Capture latest values; the trailing-edge flush reads them.
        let snapshot = LastReadSnapshot(
            bookId: bookId,
            chapterIndex: chapterIndex,
            totalChapters: totalChapters
        )
        lastReadLock.lock()
        pendingLastRead = snapshot
        lastReadLock.unlock()
        scheduleLastReadFlush()
    }

    /// Flush any pending last-read write immediately. Call from
    /// `onDisappear` (reader teardown) so the widget reflects the
    /// final position the moment the user leaves the book.
    static func flushLastRead() {
        lastReadFlushTask?.cancel()
        lastReadFlushTask = nil
        lastReadLock.lock()
        let snapshot = pendingLastRead
        pendingLastRead = nil
        lastReadLock.unlock()
        guard let snapshot else { return }
        commitLastRead(snapshot)
    }

    private struct LastReadSnapshot: Sendable, Equatable {
        let bookId: String
        let chapterIndex: Int
        let totalChapters: Int?
    }

    private static let lastReadLock = NSLock()
    nonisolated(unsafe) private static var pendingLastRead: LastReadSnapshot?
    nonisolated(unsafe) private static var lastReadFlushTask: Task<Void, Never>?

    private static func scheduleLastReadFlush() {
        lastReadFlushTask?.cancel()
        lastReadFlushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            flushLastRead()
        }
    }

    private static func commitLastRead(_ snapshot: LastReadSnapshot) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(snapshot.bookId, forKey: Keys.lastReadBookId)
        defaults.set(snapshot.chapterIndex, forKey: Keys.lastReadChapterIndex)
        if let total = snapshot.totalChapters {
            defaults.set(total, forKey: Keys.lastReadTotalChapters)
        }
        defaults.set(
            localizedChapterLabel(
                chapterIndex: snapshot.chapterIndex,
                totalChapters: snapshot.totalChapters
            ),
            forKey: Keys.lastReadChapterLabel
        )
        reloadContinueReadingWidgets()
    }

    /// The widget extension bundles no `Localizable.strings` of its own, so
    /// any user-visible label must be localized here, in the host app
    /// process, and shipped pre-rendered through the App Group payload.
    static func localizedChapterLabel(chapterIndex: Int, totalChapters: Int?) -> String {
        if let total = totalChapters, total > 0 {
            return L10n.string("player.chapterOf", chapterIndex + 1, total)
        }
        return L10n.string("player.chapter", chapterIndex + 1)
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
        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.2, *) {
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
        #endif
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
        #if canImport(ActivityKit) && os(iOS)
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
        #else
        return nil
        #endif
    }

    /// End all conversion Live Activities for the given `bookId`.
    /// Pass `failed: true` to show a failure state before dismissal.
    /// Must be called explicitly when a job reaches done/failed/cancelled —
    /// never rely on `staleDate` for cleanup.
    static func endConversionActivity(bookId: String, failed: Bool = false) {
        #if canImport(ActivityKit) && os(iOS)
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
        #endif
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
