#if os(macOS)
import AppKit
import PDFKit
import Combine

/// One document identity and presentation generation shared by Mac reader owners.
@MainActor
final class MacReaderDocument: ReaderDocument {
    var loadGeneration: UUID = UUID()
    var presentationGeneration: UUID = UUID()
    var currentBookId: String? {
        didSet { chapterNames = currentBookId.map { ChapterNameStore.shared.names(bookID: $0) } ?? [:] }
    }
    var isRestoringInitialPosition: Bool = false
    var pendingAppearanceRefresh: Bool = false

    func isActiveLoad(_ generation: UUID, bookID: String) -> Bool {
        !Task.isCancelled
            && Self.isCurrentLoad(generation: loadGeneration, current: generation, bookID: bookID, currentBookID: currentBookId)
    }
}
#endif
