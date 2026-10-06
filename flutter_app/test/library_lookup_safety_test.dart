import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/services/library_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryStore safe lookup', () {
    test(
        'looking up a missing book via `where(...).firstOrNull` returns null '
        'instead of throwing StateError("No element")', () async {
      // book_open_screen used `library.books.firstWhere(b => b.id == X)`
      // without `orElse`, so any async path that ran after the user
      // removed the book from the library threw StateError and crashed
      // the conversion flow. Slice 33 switches every such call site
      // to a null-safe lookup — pin the pattern here.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);

      final missing =
          store.books.where((b) => b.id == 'never-existed').firstOrNull;
      expect(missing, isNull);

      // The unsafe form throws — verifying the *reason* slice 33 exists.
      expect(
        () => store.books.firstWhere((b) => b.id == 'never-existed'),
        throwsStateError,
      );
    });

    test(
        'when the book exists, the null-safe lookup returns it unchanged',
        () async {
      final book = BookEntity(
        id: 'sha-abc',
        title: 'Test Book',
        author: 'Test Author',
        filePath: '/tmp/test.epub',
        displayFilename: 'test.epub',
        addedAt: DateTime(2026, 1, 1),
      );
      SharedPreferences.setMockInitialValues({
        'library.books.v1': '[${book.encode()}]',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);

      final found =
          store.books.where((b) => b.id == 'sha-abc').firstOrNull;
      expect(found, isNotNull);
      expect(found!.title, 'Test Book');
    });
  });
}
