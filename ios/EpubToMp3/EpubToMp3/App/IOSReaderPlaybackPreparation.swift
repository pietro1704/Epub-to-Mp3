#if os(iOS)
import UIKit

@MainActor
enum IOSReaderPlaybackPreparation {
    static func hydrateCachedChapterTitles(player: AudioPlayer, owner: AnyObject) {
        let activeReaderBookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let bookID = activeReaderBookID
            ?? UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        // The active reader hydrates this same catalog after its prepared
        // chapter is visible. Decoding it here would compete with that read.
        guard let bookID, bookID != activeReaderBookID else { return }
        Task { [weak owner, weak player] in
            let fulltext = await Task.detached(priority: .utility) {
                LocalFulltextCache.read(bookId: bookID)
            }.value
            guard owner != nil, let fulltext else { return }
            player?.updateReaderChapterTitles(fulltext.chapters)
        }
    }

    /// Rebuilds a paused local queue from the durable artifact manifest. This
    /// makes the mini player, expanded player, widget and lock-screen controls
    /// useful immediately after a relaunch without restarting conversion or
    /// claiming the user's audio session.
    static func restoreLocalPlaybackControls(settings: AppSettings, library: LibraryStore, player: AudioPlayer, owner: AnyObject, onRestored: @escaping @MainActor () -> Void) {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        guard let bookID else { return }
        let epubChapterIndex = UserDefaults.standard.object(
            forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey
        ) as? Int ?? 0
        Task { [weak owner] in
            guard let owner else { return }
            defer { withExtendedLifetime(owner) {} }
            let embeddedSnapshot = try? await LocalAudioArtifactStore.shared.playableSnapshot(
                bookID: bookID,
                engine: settings.audioEngine.rawValue,
                voice: "auto",
                language: nil
            )
            let conversionJobID = library.books.first(where: { $0.id == bookID })?.lastJobId
            let restoredSnapshot: JobSnapshot?
            if let conversionJobID {
                restoredSnapshot = await Task.detached(priority: .utility) {
                    let converted = RustConversionCoordinator.persistedSnapshot(jobID: conversionJobID)
                    return AudiobookDownloadStorage.restoredPlaybackSnapshot(jobId: conversionJobID,
                                                                   conversionSnapshot: converted)
                }.value
            } else {
                restoredSnapshot = nil
            }
            guard let snapshot = embeddedSnapshot ?? restoredSnapshot else {
                return
            }
            let queueOffset = AudioPlayer.restoredPlayableChapterOffset(
                snapshot: snapshot,
                persistedEpubChapterIndex: epubChapterIndex
            )
            player.play(
                snapshot: snapshot,
                startingAt: queueOffset,
                restoreAutoplay: false
            )
            onRestored()
        }
    }

    static func syncPlayerCoverArtNow(player: AudioPlayer, library: LibraryStore) {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let cover = bookID.flatMap { id in library.books.first(where: { $0.id == id })?.coverPNG }
        player.updateCoverArtData(cover)
    }

}
#endif
