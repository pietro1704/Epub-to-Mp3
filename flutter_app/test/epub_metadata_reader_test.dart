import 'dart:convert';

import 'package:flutter_app/services/conversion/epub_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';

// EPUB parsing (EPUB 2/3 covers, missing covers, invalid archives) is covered
// by converter-core and converter-ffi tests. These tests cover the Dart
// boundary: what is requested, how the Rust JSON is mapped and error handling.
void main() {
  test('maps the Rust library metadata JSON', () async {
    final requested = <String>[];
    final result = await readEpubMetadataFrom('/books/Casmurro.EPUB', (path) async {
      requested.add(path);
      return jsonEncode({
        'title': 'Dom Casmurro',
        'author': 'Machado de Assis',
        'language': 'pt-BR',
        'coverMimeType': 'image/png',
        'coverBase64': 'iVBORw0KGgo=',
      });
    });
    expect(requested, ['/books/Casmurro.EPUB']);
    expect(result.title, 'Dom Casmurro');
    expect(result.author, 'Machado de Assis');
    expect(result.coverBase64, 'iVBORw0KGgo=');
  });

  test('absent and blank fields stay empty', () async {
    final result = await readEpubMetadataFrom(
      '/books/untitled.epub',
      (_) async => jsonEncode({'title': '  ', 'author': null, 'coverBase64': null}),
    );
    expect(result.title, isNull);
    expect(result.author, isNull);
    expect(result.coverBase64, isNull);
  });

  test('non-EPUB paths are not sent to the reader', () async {
    var called = false;
    final result = await readEpubMetadataFrom('/books/scan.pdf', (_) async {
      called = true;
      return '{}';
    });
    expect(called, isFalse);
    expect(result.title, isNull);
  });

  test('reader failures and invalid output yield empty metadata', () async {
    for (final source in <LibraryMetadataSource>[
      (_) async => null,
      (_) async => '',
      (_) async => 'not json',
      (_) async => '[1, 2]',
      (_) async => throw StateError('library unavailable'),
    ]) {
      final result = await readEpubMetadataFrom('/books/broken.epub', source);
      expect(result.title, isNull);
      expect(result.author, isNull);
      expect(result.coverBase64, isNull);
    }
  });
}
