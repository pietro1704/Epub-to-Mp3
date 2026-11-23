import Foundation

/// Rebuilds a paused local queue from the durable artifact manifest after a
/// relaunch, so the mini player, expanded player, widget and lock-screen
/// controls are useful immediately without restarting conversion or claiming
/// the user's audio session. One implementation serves iOS and the Mac.
@MainActor
enum PlaybackRelaunchRestoration {
    /// Resolves the book to restore: the last played book, else the open reader.
    private static func currentBookID(location: ReaderLocation) -> String? {
        location.playingBookID ?? location.readingBookID
    }

    static func restore(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        owner: AnyObject,
        isListeningActive: @escaping @MainActor () -> Bool = { false },
        onRestored: @escaping @MainActor () -> Void
    ) {
        guard let bookID = currentBookID(location: player.location) else { return }
        let engine = settings.primaryEngine
        restore(
            bookID: bookID, player: player, owner: owner,
            isListeningActive: isListeningActive,
            loadSnapshot: {
                await persistedSnapshot(bookID: bookID, engine: engine, library: library)
            },
            onRestored: onRestored)
    }

    /// Test seam: the snapshot loader is the only part that touches disk.
    static func restore(
        bookID: String,
        player: AudioPlayer,
        owner: AnyObject,
        isListeningActive: @escaping @MainActor () -> Bool,
        loadSnapshot: @escaping @MainActor () async -> JobSnapshot?,
        onRestored: @escaping @MainActor () -> Void
    ) {
        let location = player.location
        Task { [weak owner] in
            guard owner != nil else { return }
            let snapshot = await loadSnapshot()
            // The owner may be gone, a listening start may have begun, or the
            // user may have switched book while the manifest was read.
            guard owner != nil, !isListeningActive(), player.snapshot == nil,
                  currentBookID(location: location) == bookID, let snapshot else { return }
            let readerChapter = location.readingBookID == bookID ? location.readerChapter : nil
            let playingChapter = location.playingBookID == bookID ? location.playingChapter : nil
            let chapterIndex = playingChapter ?? readerChapter ?? 0
            player.play(
                snapshot: snapshot,
                startingAt: AudioPlayer.restoredPlayableChapterOffset(
                    snapshot: snapshot, persistedEpubChapterIndex: chapterIndex),
                restoreAutoplay: false)
            onRestored()
        }
    }

    private static func persistedSnapshot(
        bookID: String, engine: String, library: LibraryStore
    ) async -> JobSnapshot? {
        let retained = try? await LocalAudioArtifactStore.shared.playableSnapshot(
            bookID: bookID, engine: engine, voice: "auto", language: nil)
        let conversionJobID = library.books.first(where: { $0.id == bookID })?.lastJobId
        let converted: JobSnapshot?
        if let conversionJobID {
            converted = await Task.detached(priority: .utility) {
                AudiobookDownloadStorage.restoredPlaybackSnapshot(
                    jobId: conversionJobID,
                    conversionSnapshot: RustConversionCoordinator.persistedSnapshot(jobID: conversionJobID))
            }.value
        } else {
            converted = nil
        }
        return LocalAudioPlaybackRestoration.snapshot(
            bookID: bookID, conversionJobID: conversionJobID, retained: retained, converted: converted)
    }
}
