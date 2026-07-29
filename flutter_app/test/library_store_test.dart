// Parity test for LibraryStore mirror.
import 'dart:io';

import 'package:flutter_app/services/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<File> _tempEpub(String name, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('lib_store_test_');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('contentHash is stable & 32 hex chars', () async {
    final f = await _tempEpub('a.epub', List.filled(100, 0x42));
    final h = await LibraryStore.contentHash(f.path);
    expect(h.length, 32);
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(h), isTrue);
    expect(h, await LibraryStore.contentHash(f.path));
  });

  test('importBook preserves an incoming display filename', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    final f = await _tempEpub('copied_123.epub', [1, 2, 3, 4, 5]);
    final book = await store.importBook(
      f.path,
      displayFilename: 'Original Book.epub',
    );
    expect(book.displayFilename, 'Original Book.epub');
  });

  test('importBook dedupes by hash', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    final f = await _tempEpub('book.epub', [1, 2, 3, 4, 5]);
    final a = await store.importBook(f.path);
    final b = await store.importBook(f.path);
    expect(a.id, b.id);
    expect(store.books.length, 1);
  });

  test('importBook missing file throws', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    expect(
      () => store.importBook('/nope/never.epub'),
      throwsA(isA<LibraryStoreException>()),
    );
  });

  test('persists across rebuilds via SharedPreferences', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    final f = await _tempEpub('persist.epub', [9, 9, 9]);
    await store.importBook(f.path);
    final reborn = LibraryStore(prefs: prefs);
    expect(reborn.books.length, 1);
    expect(reborn.books.first.displayFilename, 'persist.epub');
  });

  test('remove erases', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    final f = await _tempEpub('rm.epub', [0]);
    final b = await store.importBook(f.path);
    store.remove(b.id);
    expect(store.books, isEmpty);
  });

  test('openBookFile throws 410 when file vanished', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    final f = await _tempEpub('gone.epub', [0]);
    final b = await store.importBook(f.path);
    await f.delete();
    expect(
      () => store.openBookFile(b.id),
      throwsA(
        isA<LibraryStoreException>().having((e) => e.code, 'code', 410),
      ),
    );
  });

  test('ensureSupportedBookPath repairs extensionless Android imports', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    final f = await _tempEpub('Documento de Pietro', [0x50, 0x4b, 0x03, 0x04]);
    final book = await store.importBook(f.path);

    final repaired = await store.ensureSupportedBookPath(book);

    expect(repaired, endsWith('.epub'));
    expect(await File(repaired).exists(), isTrue);
    expect(book.filePath, repaired);
  });
}
