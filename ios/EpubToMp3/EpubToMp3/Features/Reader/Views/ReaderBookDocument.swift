#if os(iOS)
import UIKit

/// The source identity and content currently owned by a reader document.
/// Loading generations survive the loading cover so late catalog hydration can
/// be accepted only for the same source, while visible readiness has its own ID.
@MainActor
final class ReaderBookDocument: ReaderDocument {
    var book: BookEntity {
        didSet { chapterNames = ChapterNameStore.shared.names(bookID: book.id) }
    }
    var activeLoadingID: UUID?
    var loadGenerationID: UUID?
    var pendingLoadingCompletionID: UUID?
    var pendingProjectionAnchor: (loadingID: UUID, progress: ReaderProgressStore.Entry)?
    var presentedProjectionLoadingID: UUID?

    init(book: BookEntity) {
        self.book = book
        super.init()
        chapterNames = ChapterNameStore.shared.names(bookID: book.id)
    }

    func isCurrentLoad(_ loadingID: UUID, bookID: String) -> Bool {
        Self.isCurrentLoad(generation: loadingID, current: loadGenerationID, bookID: bookID, currentBookID: book.id)
    }
}
#endif
