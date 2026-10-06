import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/services/cover_writeback.dart';
import 'package:flutter_app/services/library_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LibraryStore> buildStore(List<BookEntity> books) async {
    SharedPreferences.setMockInitialValues({
      'library.books.v1': '[${books.map((b) => b.encode()).join(',')}]',
    });
    final prefs = await SharedPreferences.getInstance();
    return LibraryStore(prefs: prefs);
  }

  BookEntity bookA() => BookEntity(
        id: 'sha-A',
        title: 'A old title',
        author: 'Author',
        filePath: '/tmp/a.epub',
        displayFilename: 'a.epub',
        addedAt: DateTime(2026, 1, 1),
      );

  BookEntity bookANew() => BookEntity(
        id: 'sha-A',
        title: 'A NEW title',
        author: 'Author updated',
        filePath: '/tmp/a-renamed.epub',
        displayFilename: 'a-renamed.epub',
        addedAt: DateTime(2026, 2, 2),
      );

  group('CoverWriteback', () {
    test('happy path: writes cover when the book is present and uncovered',
        () async {
      final library = await buildStore([bookA()]);
      final ok = CoverWriteback.apply(
        library: library,
        bookId: 'sha-A',
        coverBase64: 'COVER',
      );
      expect(ok, isTrue);
      expect(library.books.first.coverBase64, 'COVER');
    });

    test('book removed during the fetch: returns false, library untouched',
        () async {
      final library = await buildStore([bookA()]);
      library.remove('sha-A');

      final ok = CoverWriteback.apply(
        library: library,
        bookId: 'sha-A',
        coverBase64: 'COVER',
      );
      expect(ok, isFalse);
      expect(library.books, isEmpty);
    });

    test('idempotent: if the live book already has a cover, no-op', () async {
      final initial = bookA()..coverBase64 = 'EARLIER';
      final library = await buildStore([initial]);

      final ok = CoverWriteback.apply(
        library: library,
        bookId: 'sha-A',
        coverBase64: 'LATER',
      );
      expect(ok, isFalse);
      expect(library.books.first.coverBase64, 'EARLIER',
          reason: 'must not overwrite a cover set by a concurrent path');
    });

    test(
        'book replaced (same id, new metadata) during the fetch: cover '
        'lands on the FRESH entity without reverting the new metadata', () async {
      // Real-world race book_open_screen could hit:
      // 1. _fetchBackendCover starts.
      // 2. await api.fetchBytes(coverUrl) is in flight.
      // 3. Library is mutated: bookA → bookANew (same id, new fields).
      // 4. Cover bytes arrive.
      // Pre-slice-34 the captured `book` reference (old metadata) had
      // its coverBase64 set and was passed to `library.update(book)`,
      // which silently reverted the title + filePath + displayFilename
      // changes from step 3. The new code re-looks-up by id so only
      // the cover changes.
      final library = await buildStore([bookA()]);
      library.update(bookANew());
      expect(library.books.first.title, 'A NEW title');

      final ok = CoverWriteback.apply(
        library: library,
        bookId: 'sha-A',
        coverBase64: 'COVER',
      );

      expect(ok, isTrue);
      expect(library.books.first.coverBase64, 'COVER');
      expect(library.books.first.title, 'A NEW title',
          reason: 'new metadata must survive the cover writeback');
      expect(library.books.first.filePath, '/tmp/a-renamed.epub');
    });
  });
}
