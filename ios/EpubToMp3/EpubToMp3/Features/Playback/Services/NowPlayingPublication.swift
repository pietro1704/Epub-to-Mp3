import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Projects confirmed playback state to the system and App Group. Timeline
/// reload identity belongs here, separate from the playback coordinator.
@MainActor
final class NowPlayingPublication {
    private let location: ReaderLocation

    init(location: ReaderLocation = .standard) {
        self.location = location
    }

    /// Last (bookId, chapterName, isPlaying) tuple pushed to the widget via
    /// the RELOADING `WidgetDataSync.updateNowPlaying`. `syncWidgetNowPlaying()`
    /// runs on every ~1Hz Now Playing refresh during playback, but
    /// `WidgetCenter.reloadTimelines` is a cross-process XPC call to
    /// `widgetkitd` — firing it every second (three kinds at once) queues up
    /// widgetkitd work and made the widget's own play button feel like it
    /// "trava e fica pesado" under repeated taps, because each tap's
    /// `resume()` → `updateNowPlayingInfo()` added another reload burst on
    /// top of an already-backlogged queue. Only the fields that actually
    /// changed (chapter advance, play/pause) warrant a timeline reload;
    /// bare progress ticks use `updateNowPlayingProgress` (write-only, no
    /// `reloadTimelines` call).
    /// Throttle for `MPNowPlayingInfoCenter` updates — we update at most
    /// once per second so the lock-screen scrubber stays fresh without
    /// hitting the system's info center on every 250ms tick.
    private var lastTick: Date = .distantPast
    func shouldPublishTick(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(lastTick) >= 1 else { return false }
        lastTick = now
        return true
    }
    private var lastSyncedWidgetState: (bookId: String, chapterName: String?, isPlaying: Bool)?
    /// Updates system artwork only when the active book's cover changes.
    /// Both native shells call this as their library and playback pointers
    /// refresh, keeping macOS and iOS Now Playing metadata in sync.
    func publish(_ state: PlaybackTransportState.Sample) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = makeInfo(state)
        syncWidgetNowPlaying(state)
    }
    func makeInfo(_ state: PlaybackTransportState.Sample) -> [String: Any] {
        var info: [String: Any] = [:]
        let bookTitle = state.content.job?.bookTitle ?? "Epub-to-Mp3"
        let chapterTitle = state.content.chapterTitle
        // The chapter is the primary Now Playing label; the book remains
        // secondary metadata so Control Center and the lock screen identify
        // the exact text currently being read.
        info[MPMediaItemPropertyTitle] = chapterTitle
        info[MPMediaItemPropertyAlbumTitle] = bookTitle
        // The system player should identify the audiobook author when
        // available. Falling back to the book title keeps older backend
        // snapshots useful without emitting an empty artist field.
        info[MPMediaItemPropertyArtist] = state.content.job?.bookAuthor ?? bookTitle
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.clock.positionSeconds
        info[MPMediaItemPropertyPlaybackDuration] = state.clock.durationSeconds > 0 ? state.clock.durationSeconds : 0
        // Rate = 0 when paused; actual rate when playing. The system uses
        // this to animate the scrubber in real time on the lock screen.
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.content.isPlaying ? state.content.rate.rawValue : 0.0
        // Default rate tells the lock-screen widget what "1x" means so
        // the rate indicator renders correctly at non-standard speeds.
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = Float(1.0)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue

        if let coverArtData = state.content.coverArtData, let artwork = makeArtwork(from: coverArtData) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        return info
    }

    private func syncWidgetNowPlaying(_ state: PlaybackTransportState.Sample) {
        let appGroupDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        guard let bookId = appGroupDefaults?.string(forKey: "currentlyPlayingBookId")
                ?? location.playingBookID,
              !bookId.isEmpty else { return }
        let progress = state.clock.durationSeconds > 0
            ? min(1, max(0, state.clock.positionSeconds / state.clock.durationSeconds))
            : 0
        let chapters = state.content.job?.playableChapters ?? []
        let currentIndex = max(0, min(state.content.chapterIndex, max(chapters.count - 1, 0)))
        // Keep the widget on the same canonical title as the mini player and
        // Now Playing metadata. `currentChapterValue.displayTitle` can still
        // be the generated fallback when the reader has the real TOC title.
        let chapterName = state.content.chapterTitle
        let totalChapters = chapters.isEmpty ? nil : chapters.count
        let chapterRemaining = PlaybackChapterQueue.rateAdjustedDuration(
            seconds: max(0, state.clock.durationSeconds - state.clock.positionSeconds), rate: state.content.rate
        )
        let followingRemaining = chapters.dropFirst(min(currentIndex + 1, chapters.count))
            .compactMap(\.durationSeconds)
            .filter { $0.isFinite && $0 > 0 }
            .reduce(0) { total, duration in
                total + PlaybackChapterQueue.rateAdjustedDuration(seconds: duration, rate: state.content.rate)
            }
        let bookRemaining = chapterRemaining + followingRemaining
        let timing = (
            position: state.playbackPositionSeconds,
            duration: state.playbackDurationSeconds,
                      chapterRemaining: chapterRemaining, bookRemaining: bookRemaining,
                      totalChapters: totalChapters)
        let widgetState = (bookId: bookId, chapterName: chapterName, isPlaying: state.content.isPlaying)

        // Only pay for a `WidgetCenter.reloadTimelines` IPC round-trip when
        // the book, chapter, or transport state actually changed. A bare
        // progress tick (the common case — fires every ~1s during playback)
        // writes the new value without asking widgetkitd to rebuild.
        guard Self.widgetSyncNeedsReload(last: lastSyncedWidgetState, current: widgetState) else {
            WidgetDataSync.updateNowPlayingProgress(progress)
            WidgetDataSync.updateNowPlayingTiming(
                positionSeconds: timing.position,
                durationSeconds: timing.duration,
                chapterRemainingSeconds: timing.chapterRemaining,
                bookRemainingSeconds: timing.bookRemaining,
                totalChapters: timing.totalChapters
            )
            return
        }
        lastSyncedWidgetState = widgetState
        WidgetDataSync.updateNowPlaying(
            bookId: bookId,
            chapterName: chapterName,
            author: state.content.job?.bookAuthor,
            progress: progress,
            isPlaying: state.content.isPlaying,
            positionSeconds: timing.position,
            durationSeconds: timing.duration,
            chapterRemainingSeconds: timing.chapterRemaining,
            bookRemainingSeconds: timing.bookRemaining,
            totalChapters: timing.totalChapters
        )
    }

    /// Push the real playback state to the App Group so the home-screen /
    /// lock-screen widgets never show a stale play/pause affordance.
    /// Called from every site that already calls `updateNowPlayingInfo()`
    /// (play, pause, resume, chapter advance) — the single choke point for
    /// "did the transport state change" in this class. Previously only
    /// `PlaybackBindingStore.setCurrentlyPlaying` wrote to the widget, and only
    /// once, when a book was opened — the widget then never learned about
    /// a later pause, so it showed "pause" forever.
    /// Pure decision helper behind `syncWidgetNowPlaying()`: does the new
    /// (bookId, chapterName, isPlaying) tuple require a full, RELOADING
    /// `WidgetDataSync.updateNowPlaying` call, or can this tick get away
    /// with the reload-free `updateNowPlayingProgress`? Extracted so the
    /// dedup logic is unit-testable without spinning up a real
    /// `WidgetCenter`/App Group round-trip.
    nonisolated static func widgetSyncNeedsReload(
        last: (bookId: String, chapterName: String?, isPlaying: Bool)?,
        current: (bookId: String, chapterName: String?, isPlaying: Bool)
    ) -> Bool {
        guard let last else { return true }
        return last.bookId != current.bookId
            || last.chapterName != current.chapterName
            || last.isPlaying != current.isPlaying
    }

    private func makeArtwork(from data: Data) -> MPMediaItemArtwork? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #else
        guard let image = NSImage(data: data) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        #endif
    }

}
