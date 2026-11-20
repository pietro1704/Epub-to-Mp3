import Foundation

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

    static func syncPlayerCoverArtNow(player: AudioPlayer, library: LibraryStore) {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let cover = bookID.flatMap { id in library.books.first(where: { $0.id == id })?.coverPNG }
        player.updateCoverArtData(cover)
    }

}
