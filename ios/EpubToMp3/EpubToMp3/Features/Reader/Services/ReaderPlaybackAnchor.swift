import Foundation

/// Translates the reader's array position into the canonical zero-based EPUB
/// axis used by conversion, local artifacts, and playback. The two axes only
/// happen to match for simple books; front matter and sparse TOCs make them
/// diverge.
enum ReaderPlaybackAnchor {
    static func epubIndex(
        forReaderPosition position: Int,
        in chapters: [EbookFulltext.Chapter]
    ) -> Int? {
        guard chapters.indices.contains(position) else { return nil }
        return chapters[position].zeroBasedEpubIndex
    }

    /// Publishes the reader's live playback anchor in the EPUB chapter axis.
    /// The reader list can contain front matter and sparse TOC entries, while
    /// audio artifacts are always indexed by their original EPUB position.
    @MainActor
    @discardableResult
    static func publish(
        readerPosition: Int,
        chapters: [EbookFulltext.Chapter],
        offsetFraction: Double,
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard let epubIndex = epubIndex(forReaderPosition: readerPosition, in: chapters) else {
            return nil
        }
        return publish(epubIndex: epubIndex, offsetFraction: offsetFraction, defaults: defaults)
    }

    @MainActor
    @discardableResult
    static func publish(chapter: EbookFulltext.Chapter, offsetFraction: Double,
                        defaults: UserDefaults = .standard) -> Int {
        publish(epubIndex: chapter.zeroBasedEpubIndex, offsetFraction: offsetFraction, defaults: defaults)
    }

    @MainActor
    private static func publish(epubIndex: Int, offsetFraction: Double, defaults: UserDefaults) -> Int {
        let location = ReaderLocation(defaults: defaults)
        location.setReaderAnchor(chapter: epubIndex, pageRatio: min(max(offsetFraction.isFinite ? offsetFraction : 0, 0), 1))
        return epubIndex
    }
}

/// Resolves the chapter that should be synthesized first when playback starts.
/// The live reader cursor wins for the book currently open on screen; saved
/// progress remains the fallback for starts initiated outside the reader.
@MainActor
enum ReaderPlaybackPriorityChapter {
    static func index(
        bookID: String,
        chapters: [EbookFulltext.Chapter]? = nil,
        defaults: UserDefaults = .standard
    ) -> Int {
        index(bookID: bookID, chapters: chapters, location: ReaderLocation(defaults: defaults), progressDefaults: defaults)
    }

    static func index(bookID: String, chapters: [EbookFulltext.Chapter]? = nil, location: ReaderLocation,
                      progressDefaults: UserDefaults = .standard) -> Int {
        if location.readingBookID == bookID, let liveIndex = location.readerChapter {
            return max(0, liveIndex)
        }

        guard let readerPosition = ReaderProgressStore.read(bookId: bookID, defaults: progressDefaults)?.chapterIndex else {
            return 0
        }
        let resolvedChapters = chapters ?? LocalFulltextCache.read(bookId: bookID)?.chapters ?? []
        return ReaderPlaybackAnchor.epubIndex(
            forReaderPosition: readerPosition,
            in: resolvedChapters
        ) ?? readerPosition
    }
}
