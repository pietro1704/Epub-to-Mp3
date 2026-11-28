import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../storage/library_store.dart';
import 'desktop_embedded_converter.dart';

/// Sends one shelf request JSON to the shared Rust reader and returns its answer, or null.
typedef LibraryShelfSource = Future<String?> Function(String requestJson);

/// Thumbnail edge, in pixels, of a shelf cover (the Rust default).
const libraryShelfCoverEdge = 480;

/// Reads the metadata and a thumbnail cover of every EPUB in [paths] with one call to the
/// shared Rust reader. The result matches [paths] by position; a book that cannot be read,
/// or a failed call, gives null. Never throws.
Future<List<EpubMetadata?>> readLibraryShelf(
  List<String> paths, {
  int coverMaxEdge = libraryShelfCoverEdge,
}) => readLibraryShelfFrom(paths, _platformShelf, coverMaxEdge: coverMaxEdge);

Future<List<EpubMetadata?>> readLibraryShelfFrom(
  List<String> paths,
  LibraryShelfSource source, {
  int coverMaxEdge = libraryShelfCoverEdge,
}) async {
  final empty = List<EpubMetadata?>.filled(paths.length, null);
  if (paths.isEmpty) return empty;
  try {
    final raw = await source(
      jsonEncode({'paths': paths, 'coverMaxEdge': coverMaxEdge}),
    );
    if (raw == null || raw.isEmpty) return empty;
    final books = (jsonDecode(raw) as Map<String, dynamic>)['books'];
    if (books is! List || books.length != paths.length) return empty;
    String? text(Map<String, dynamic> book, String key) {
      final value = book[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return [
      for (final book in books)
        book is Map<String, dynamic> && book['error'] == null
            ? EpubMetadata(
                title: text(book, 'title'),
                author: text(book, 'author'),
                coverBase64: text(book, 'coverBase64'),
              )
            : null,
    ];
  } catch (error) {
    debugPrint('Library shelf unavailable: $error');
    return empty;
  }
}

const _channel = MethodChannel('epub_to_mp3/embedded_converter');

Future<String?> _platformShelf(String requestJson) {
  if (Platform.isAndroid) {
    return _channel.invokeMethod<String>('libraryShelf', {
      'request': requestJson,
    });
  }
  return desktopLibraryShelfJson(requestJson);
}
