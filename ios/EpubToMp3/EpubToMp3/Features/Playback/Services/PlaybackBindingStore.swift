import Foundation

/// Persists the lightweight playback pointer used by the app shell,
/// widgets, and deep links to rehydrate the active audiobook without
/// keeping an unused landing view alive just for this helper.
enum PlaybackBindingStore {

    /// Persist the current (bookID, chapterIndex) pair. Binding a book
    /// to playback does not imply transport is currently running, so the
    /// widget sync always writes `isPlaying: false` here and leaves real
    /// transport updates to `AudioPlayer.updateNowPlayingInfo()`.
    static func setCurrentlyPlaying(
        bookID: String?,
        chapterIndex: Int,
        chapterName: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        ReaderLocation(defaults: defaults).bindPlayingBook(bookID, chapter: chapterIndex)

        WidgetDataSync.updateNowPlaying(
            bookId: bookID,
            chapterName: chapterName,
            progress: 0,
            isPlaying: false
        )
    }
}
