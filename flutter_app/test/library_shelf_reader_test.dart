import 'dart:convert';

import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/services/conversion/library_shelf_reader.dart';
import 'package:flutter_app/services/storage/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('one request carries every EPUB path and the cover edge', () async {
    final requests = <Map<String, dynamic>>[];
    final result = await readLibraryShelfFrom(['/b/a.epub', '/b/b.epub'], (
      request,
    ) async {
      requests.add(jsonDecode(request) as Map<String, dynamic>);
      return jsonEncode({
        'books': [
          {'title': 'A', 'author': 'X', 'coverBase64': 'AAAA', 'error': null},
          {'title': null, 'coverBase64': null, 'error': 'broken'},
        ],
      });
    }, coverMaxEdge: 240);
    expect(requests, [
      {
        'paths': ['/b/a.epub', '/b/b.epub'],
        'coverMaxEdge': 240,
      },
    ]);
    expect(result[0]?.title, 'A');
    expect(result[0]?.coverBase64, 'AAAA');
    expect(result[1], isNull);
  });

  test('a failed batch yields no metadata instead of throwing', () async {
    expect(await readLibraryShelfFrom(['/b/a.epub'], (_) async => null), [
      null,
    ]);
  });

  test('the store refreshes the whole shelf with a single call', () async {
    BookEntity book(String name, String? cover) => BookEntity(
      id: name,
      title: name,
      filePath: '/b/$name',
      displayFilename: name,
      addedAt: DateTime(2025),
      coverBase64: cover,
    );
    final books = [
      book('a.epub', 'full-a'),
      book('b.epub', 'full-b'),
      book('c.epub', null),
      book('scan.pdf', null),
    ];
    SharedPreferences.setMockInitialValues({
      'library.books.v1': '[${books.map((b) => b.encode()).join(',')}]',
    });
    final prefs = await SharedPreferences.getInstance();
    var calls = 0;
    final store = LibraryStore(
      prefs: prefs,
      shelfReader: (paths) async {
        calls++;
        return [
          for (final path in paths) EpubMetadata(coverBase64: 'thumb-$path'),
        ];
      },
    );
    await store.refreshShelf();
    expect(calls, 1);
    expect(store.books.map((b) => b.coverBase64), [
      'thumb-/b/a.epub',
      'thumb-/b/b.epub',
      'thumb-/b/c.epub',
      null,
    ]);
  });
}
