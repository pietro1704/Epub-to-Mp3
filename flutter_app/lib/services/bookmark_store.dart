// Mirror of ios/EpubToMp3/EpubToMp3/Services/BookmarkStore.swift
//
// SharedPreferences-backed CRUD for bookmarks and highlights.
// Follows the same ChangeNotifier pattern as LibraryStore so the
// Riverpod provider can expose it as a listenable.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/bookmark.dart';

class BookmarkStore extends ChangeNotifier {
  BookmarkStore({
    required SharedPreferences prefs,
    this.storageKey = 'bookmarks.v1',
  }) : _prefs = prefs {
    _load();
  }

  final SharedPreferences _prefs;
  final String storageKey;

  final List<Bookmark> _bookmarks = [];

  List<Bookmark> get bookmarks => List.unmodifiable(_bookmarks);

  // ---------- Queries ----------------------------------------------------

  /// All bookmarks for a given book, newest first.
  List<Bookmark> bookmarksForBook(String bookId) => _bookmarks
      .where((b) => b.bookId == bookId)
      .toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// All bookmarks in a specific chapter, ordered by startChar.
  List<Bookmark> bookmarksForChapter(String bookId, int chapterIndex) =>
      _bookmarks
          .where(
              (b) => b.bookId == bookId && b.chapterIndex == chapterIndex)
          .toList()
        ..sort((a, b) => a.startChar.compareTo(b.startChar));

  /// Position-only bookmarks (no selected text).
  List<Bookmark> pageBookmarks(String bookId) =>
      bookmarksForBook(bookId).where((b) => !b.isHighlight).toList();

  /// Text highlights only.
  List<Bookmark> highlights(String bookId) =>
      bookmarksForBook(bookId).where((b) => b.isHighlight).toList();

  /// Whether a position bookmark exists in a chapter (ignores highlights).
  bool hasBookmark(String bookId, int chapterIndex) => _bookmarks.any(
      (b) => b.bookId == bookId && b.chapterIndex == chapterIndex && !b.isHighlight);

  // ---------- Mutations --------------------------------------------------

  Bookmark addBookmark({
    required String bookId,
    required int chapterIndex,
    required String chapterTitle,
    int startChar = 0,
    int endChar = 0,
    String selectedText = '',
    String? note,
    HighlightColor color = HighlightColor.yellow,
  }) {
    final entry = Bookmark(
      id: const Uuid().v4(),
      bookId: bookId,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      startChar: startChar,
      endChar: endChar,
      selectedText: selectedText,
      note: note,
      color: color,
      createdAt: DateTime.now(),
    );
    _bookmarks.add(entry);
    _persist();
    notifyListeners();
    return entry;
  }

  void updateNote(String id, String? note) {
    final i = _bookmarks.indexWhere((b) => b.id == id);
    if (i < 0) return;
    _bookmarks[i].note = note;
    _persist();
    notifyListeners();
  }

  void updateColor(String id, HighlightColor color) {
    final i = _bookmarks.indexWhere((b) => b.id == id);
    if (i < 0) return;
    _bookmarks[i].color = color;
    _persist();
    notifyListeners();
  }

  void remove(String id) {
    _bookmarks.removeWhere((b) => b.id == id);
    _persist();
    notifyListeners();
  }

  void removeAll(String bookId) {
    _bookmarks.removeWhere((b) => b.bookId == bookId);
    _persist();
    notifyListeners();
  }

  // ---------- Persistence ------------------------------------------------

  void _load() {
    final raw = _prefs.getString(storageKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(Bookmark.fromJson)
          .toList();
      _bookmarks
        ..clear()
        ..addAll(list);
    } catch (_) {
      // Corrupted data — start fresh.
    }
  }

  void _persist() {
    final encoded = jsonEncode(
      _bookmarks.map((b) => b.toJson()).toList(growable: false),
    );
    _prefs.setString(storageKey, encoded);
  }
}
