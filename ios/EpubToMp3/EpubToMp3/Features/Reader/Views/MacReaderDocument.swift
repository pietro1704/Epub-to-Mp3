#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit
import Combine

/// One document identity and presentation generation shared by Mac reader owners.
@MainActor
final class MacReaderDocument {
    var loadGeneration: UUID = UUID()
    var presentationGeneration: UUID = UUID()
    var activeBookOpenJourneyID: UUID?
    var pendingPDFPageJourneyID: UUID?
    var firstPDFPageReadyJourneyID: UUID?
    var controlsReadyJourneyID: UUID?
    var fulltext: EbookFulltext?
    var activePreparedChapter: PreparedReaderChapterStore.Snapshot?
    var lastPreparedChapterOrdinal: Int?
    var selectedChapter: Int = 0
    var currentBookId: String?
    var hasRestoredInitialPosition: Bool = false
    var isRestoringInitialPosition: Bool = false
    var pendingAppearanceRefresh: Bool = false
    var registeredFontURLs: [URL] = []
    var fontDirectoryURL: URL? { registeredFontURLs.first?.deletingLastPathComponent() }

    deinit {
        if let journeyID = activeBookOpenJourneyID {
            _ = LatencyObservationStore.shared.cancel(journeyID)
        }
    }

    func isActiveLoad(_ generation: UUID, bookID: String) -> Bool {
        !Task.isCancelled && loadGeneration == generation && currentBookId == bookID
    }

    func chapter(at ordinal: Int) -> EbookFulltext.Chapter? {
        if let fulltext { return fulltext.chapters.indices.contains(ordinal) ? fulltext.chapters[ordinal] : nil }
        return activePreparedChapter?.chapterOrdinal == ordinal ? activePreparedChapter?.chapter : nil
    }

    var tocRows: [ReaderTocRow] {
        guard let fulltext else { return [] }
        return ReaderTocFlattener.rows(toc: fulltext.toc, chapters: fulltext.chapters)
    }
}
#endif
