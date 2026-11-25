import Foundation

@MainActor
enum IOSReaderPlaybackPreparation {
    static func hydrateCachedChapterTitles(player: AudioPlayer, owner: AnyObject) {
        let activeReaderBookID = player.location.readingBookID
        let bookID = activeReaderBookID
            ?? player.location.playingBookID
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
        let bookID = player.location.playingBookID
            ?? player.location.readingBookID
        let cover = bookID.flatMap { id in library.books.first(where: { $0.id == id })?.coverPNG }
        player.updateCoverArtData(cover)
    }

}
