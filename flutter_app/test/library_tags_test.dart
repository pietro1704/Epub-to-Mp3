// Tag CRUD + filtering tests for LibraryStore & BookEntity.
import 'dart:io';

import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/services/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<File> _tempEpub(String name, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('tag_test_');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('BookEntity tags', () {
    test('default tags is empty list', () {
      final b = BookEntity(
        id: 'x',
        title: 'T',
        filePath: '/x',
        displayFilename: 'x.epub',
        addedAt: DateTime(2026, 1, 1),
      );
      expect(b.tags, isEmpty);
    });

    test('tags roundtrip through JSON', () {
      final b = BookEntity(
        id: 'x',
        title: 'T',
        filePath: '/x',
        displayFilename: 'x.epub',
        addedAt: DateTime.utc(2026, 1, 1),
        tags: ['sci-fi', 'classic'],
      );
      final round = BookEntity.fromJson(b.toJson());
      expect(round.tags, ['sci-fi', 'classic']);
    });

    test('missing tags in JSON defaults to empty list', () {
      final json = {
        'id': 'x',
        'title': 'T',
        'filePath': '/x',
        'displayFilename': 'x.epub',
        'addedAt': '2026-01-01T00:00:00.000Z',
        'cachedOffline': false,
      };
      final b = BookEntity.fromJson(json);
      expect(b.tags, isEmpty);
    });
  });

  group('LibraryStore tag CRUD', () {
    test('addTag appends and persists', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      final f = await _tempEpub('a.epub', [1, 2]);
      final book = await store.importBook(f.path);

      store.addTag('fiction', bookId: book.id);
      expect(store.books.first.tags, ['fiction']);

      // Persists across rebuilds
      final reborn = LibraryStore(prefs: prefs);
      expect(reborn.books.first.tags, ['fiction']);
    });

    test('addTag normalises whitespace and skips duplicates', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      final f = await _tempEpub('b.epub', [3, 4]);
      final book = await store.importBook(f.path);

      store.addTag('  sci-fi  ', bookId: book.id);
      store.addTag('sci-fi', bookId: book.id); // duplicate
      store.addTag('   ', bookId: book.id); // blank
      expect(store.books.first.tags, ['sci-fi']);
    });

    test('removeTag removes and persists', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      final f = await _tempEpub('c.epub', [5, 6]);
      final book = await store.importBook(f.path);

      store.addTag('a', bookId: book.id);
      store.addTag('b', bookId: book.id);
      store.removeTag('a', bookId: book.id);
      expect(store.books.first.tags, ['b']);

      final reborn = LibraryStore(prefs: prefs);
      expect(reborn.books.first.tags, ['b']);
    });

    test('allTags aggregates from all books, sorted', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      final f1 = await _tempEpub('d.epub', [7]);
      final f2 = await _tempEpub('e.epub', [8]);
      final b1 = await store.importBook(f1.path);
      final b2 = await store.importBook(f2.path);

      store.addTag('zebra', bookId: b1.id);
      store.addTag('alpha', bookId: b2.id);
      store.addTag('alpha', bookId: b1.id); // shared tag
      expect(store.allTags, ['alpha', 'zebra']);
    });

    test('booksWithTag filters correctly', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      final f1 = await _tempEpub('f.epub', [9]);
      final f2 = await _tempEpub('g.epub', [10]);
      final b1 = await store.importBook(f1.path);
      await store.importBook(f2.path);

      store.addTag('tagged', bookId: b1.id);
      final filtered = store.booksWithTag('tagged');
      expect(filtered.length, 1);
      expect(filtered.first.id, b1.id);
    });

    test('addTag on unknown bookId is no-op', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      // Should not throw
      store.addTag('tag', bookId: 'nonexistent');
      expect(store.allTags, isEmpty);
    });
  });
}
