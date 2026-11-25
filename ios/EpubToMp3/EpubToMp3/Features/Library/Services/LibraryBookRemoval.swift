import Foundation

/// Removes one book from the library together with the data the app derived
/// from it. The iOS and macOS library screens both run this single sequence
/// after the listener confirms "Remove from library".
///
/// Order and failure handling are part of the contract:
/// 1. Converted Rust audio for the book (and the entity's legacy job folder),
///    which first posts `RustConversionOutputStore.willRemoveAudio` so active
///    playback of this book stops; then, inside that same maintenance window,
///    the book's local audio artifacts and the legacy `Audiobooks/<jobId>`
///    download.
/// 2. Bookmarks and highlights, the prepared reader text, extracted fonts,
///    prepared reader chapters and rendered chapter archives, the book's
///    pronunciations and language corrections, and the legacy job's reader text.
/// 3. The library entity, which also evicts the saved reading position.
///
/// `FulltextStore.evict(jobId:)` resolves its path through `fulltextURL(for:)`,
/// which recreates the emptied `Audiobooks/<jobId>` folder; only that empty
/// directory remains, as before this sequence was shared.
///
/// A failure in step 1 is thrown before anything in steps 2–3 runs, so the
/// book stays in the library and the listener can retry. Steps 2–3 and the
/// legacy-download deletion do not report failures; they never did. The source file the
/// listener imported is never deleted.
@MainActor
struct LibraryBookRemoval {
    let library: LibraryStore
    let bookmarks: BookmarkStore
    var convertedAudio: RustConversionOutputStore = .shared
    var localAudio: LocalAudioArtifactStore = .shared
    var legacyDownloads: AudiobookDownloads = .shared
    var preparedReader: PreparedReaderChapterStore = .shared
    var preparedRenderings = PreparedChapterArchiveStore()
    var pronunciations = BookPronunciationStore()
    var languageCorrections = BookLanguageCorrections()
    var languageSummaries = BookLanguageSummaries()

    /// `legacyJobID` is the entity's `lastJobId` as the caller read it.
    func remove(bookID: String, legacyJobID: String?) async throws {
        let localAudio = localAudio
        let legacyDownloads = legacyDownloads
        // A migration still copying this book's legacy audio must not outlive its removal.
        await legacyDownloads.quiesceLegacyMigration()
        try await convertedAudio.removeAudio(bookID: bookID, legacyJobID: legacyJobID) {
            try await localAudio.removeAllAudio(bookID: bookID)
            if let legacyJobID {
                await legacyDownloads.clearDownloadedBook(jobId: legacyJobID)
            }
        }
        bookmarks.removeAll(for: bookID)
        LocalFulltextCache.evict(bookId: bookID)
        EpubFontManager.evictCachedFonts(bookID: bookID)
        try? await preparedReader.removeAll(bookID: bookID)
        try? await preparedRenderings.removeAll(bookID: bookID)
        pronunciations.remove(bookID: bookID)
        try? languageCorrections.remove(bookID: bookID)
        languageSummaries.remove(bookID: bookID)
        if let legacyJobID { FulltextStore.evict(jobId: legacyJobID) }
        library.remove(id: bookID)
    }
}
