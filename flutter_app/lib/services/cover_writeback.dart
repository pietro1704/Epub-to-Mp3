import 'library_store.dart';

/// Race-safe writeback for a cover image into `LibraryStore`.
///
/// Pre-slice-34 `book_open_screen._fetchBackendCover` captured the
/// `BookEntity` reference BEFORE awaiting `api.fetchBytes(coverUrl)`,
/// then mutated and `library.update`-d that reference once the bytes
/// arrived. If the user removed the book or re-imported it (same id,
/// new metadata) during the in-flight HTTP request, the writeback
/// either no-op'd (`update` finds nothing by id) or silently reverted
/// the new metadata (writing the old captured book over the live
/// one).
///
/// This helper re-looks up the book by id at writeback time and
/// applies only the cover field. New metadata survives.
class CoverWriteback {
  /// Returns `true` when the cover was written, `false` when the
  /// book is no longer in the library or already has a cover.
  static bool apply({
    required LibraryStore library,
    required String bookId,
    required String coverBase64,
  }) {
    final book = library.books.where((b) => b.id == bookId).firstOrNull;
    if (book == null) return false;
    if (book.coverBase64 != null) return false;
    book.coverBase64 = coverBase64;
    library.update(book);
    return true;
  }
}
