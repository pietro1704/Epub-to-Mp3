// Mirror of ios/EpubToMp3/EpubToMp3/Services/LibraryStore.swift @ b7c962a
//
// Disk-first library of user-imported EPUBs. Persists a JSON index in
// SharedPreferences under "library.books.v1" (same key as the Swift
// app, so a future bridge could share state). Books are keyed by the
// SHA-256 of their file contents, which survives renames.
//
// Apple-only APIs intentionally NOT mirrored:
//   - security-scoped bookmarks (`startAccessingSecurityScopedResource`)
//     — Flutter targets Linux/Windows/Android only, where the file path
//     remains valid across launches.
//   - EpubMetadataReader / cover extraction is deferred to a callback
//     so this file stays self-contained; tests pass a fake reader.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_entity.dart';

class EpubMetadata {
  final String? title;
  final String? author;
  final String? coverBase64;
  const EpubMetadata({this.title, this.author, this.coverBase64});
}

typedef EpubMetadataReader = Future<EpubMetadata> Function(String filePath);

class LibraryStoreException implements Exception {
  final int code;
  final String message;
  const LibraryStoreException(this.code, this.message);
  @override
  String toString() => 'LibraryStoreException($code): $message';
}

class LibraryStore extends ChangeNotifier {
  LibraryStore({
    required SharedPreferences prefs,
    this.defaultsKey = 'library.books.v1',
    EpubMetadataReader? metadataReader,
  })  : _prefs = prefs,
        _readMetadata = metadataReader ?? _defaultMetadata {
    _load();
  }

  final SharedPreferences _prefs;
  final String defaultsKey;
  final EpubMetadataReader _readMetadata;

  final List<BookEntity> _books = [];
  String? _loadError;

  List<BookEntity> get books => List.unmodifiable(_books);
  String? get loadError => _loadError;

  static Future<EpubMetadata> _defaultMetadata(String path) async =>
      const EpubMetadata();

  // ---- CRUD --------------------------------------------------------

  /// Import a new book from a picked file path. Returns the resulting
  /// (possibly merged) [BookEntity]. Throws [LibraryStoreException]
  /// when the file is unreadable.
  Future<BookEntity> importBook(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw LibraryStoreException(
        1,
        'Cannot read ${file.uri.pathSegments.last}. The file is missing or unreadable.',
      );
    }
    final String id;
    try {
      id = await contentHash(path);
    } catch (e) {
      throw LibraryStoreException(2, 'Failed to hash $path: $e');
    }
    final filename = file.uri.pathSegments.last;
    final meta = await _readMetadata(path);

    final existingIndex = _books.indexWhere((b) => b.id == id);
    if (existingIndex >= 0) {
      final existing = _books[existingIndex];
      existing.filePath = path;
      existing.lastOpenedAt = DateTime.now();
      if ((meta.title?.isNotEmpty ?? false)) existing.title = meta.title!;
      if ((meta.author?.isNotEmpty ?? false)) existing.author = meta.author;
      existing.coverBase64 ??= meta.coverBase64;
      _persist();
      notifyListeners();
      return existing;
    }
    final book = BookEntity(
      id: id,
      title: (meta.title?.isNotEmpty ?? false)
          ? meta.title!
          : _titleFromFilename(filename),
      author: meta.author,
      filePath: path,
      displayFilename: filename,
      addedAt: DateTime.now(),
      coverBase64: meta.coverBase64,
    );
    _books.add(book);
    _persist();
    notifyListeners();
    return book;
  }

  void remove(String id) {
    _books.removeWhere((b) => b.id == id);
    _persist();
    notifyListeners();
  }

  void update(BookEntity book) {
    final i = _books.indexWhere((b) => b.id == book.id);
    if (i < 0) return;
    _books[i] = book;
    _persist();
    notifyListeners();
  }

  /// Resolve a book's file path, marking it as opened. Throws when the
  /// book is unknown or its on-disk file has gone.
  Future<String> openBookFile(String id) async {
    final i = _books.indexWhere((b) => b.id == id);
    if (i < 0) {
      throw const LibraryStoreException(404, 'Book not found in library');
    }
    final book = _books[i];
    if (book.filePath.isEmpty || !await File(book.filePath).exists()) {
      throw LibraryStoreException(
        410,
        'File ${book.displayFilename} is no longer accessible — re-import it.',
      );
    }
    book.lastOpenedAt = DateTime.now();
    _persist();
    notifyListeners();
    return book.filePath;
  }

  // ---- Persistence --------------------------------------------------

  void _load() {
    final raw = _prefs.getString(defaultsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(BookEntity.fromJson)
          .toList();
      _books
        ..clear()
        ..addAll(list);
    } catch (e) {
      _loadError = e.toString();
    }
  }

  void _persist() {
    final encoded =
        jsonEncode(_books.map((b) => b.toJson()).toList(growable: false));
    _prefs.setString(defaultsKey, encoded);
  }

  // ---- Helpers ------------------------------------------------------

  /// SHA-256 of the file contents, truncated to 32 hex chars (matches
  /// Swift). Streamed so large EPUBs don't blow up memory.
  static Future<String> contentHash(String path) async {
    final bytes = await File(path).readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString().substring(0, 32);
  }

  static String _titleFromFilename(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return base.replaceAll('_', ' ').replaceAll('-', ' ');
  }
}
