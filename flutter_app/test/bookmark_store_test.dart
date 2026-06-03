import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/bookmark.dart';
import 'package:flutter_app/services/bookmark_store.dart';

void main() {
  late BookmarkStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    store = BookmarkStore(prefs: prefs, storageKey: 'bookmarks.test');
  });

  test('addBookmark persists and notifies', () {
    var notified = false;
    store.addListener(() => notified = true);

    final bm = store.addBookmark(
      bookId: 'book-1',
      chapterIndex: 2,
      chapterTitle: 'Chapter 2',
    );

    expect(bm.bookId, 'book-1');
    expect(bm.chapterIndex, 2);
    expect(bm.isHighlight, false);
    expect(store.bookmarks.length, 1);
    expect(notified, true);
  });

  test('remove deletes by id', () {
    final bm = store.addBookmark(
      bookId: 'book-1',
      chapterIndex: 0,
      chapterTitle: 'Intro',
    );
    expect(store.bookmarks.length, 1);

    store.remove(bm.id);
    expect(store.bookmarks.length, 0);
  });

  test('updateNote and updateColor mutate in place', () {
    final bm = store.addBookmark(
      bookId: 'book-1',
      chapterIndex: 1,
      chapterTitle: 'Ch 1',
      selectedText: 'some highlighted text',
      color: HighlightColor.yellow,
    );
    expect(bm.isHighlight, true);

    store.updateNote(bm.id, 'Great passage');
    expect(store.bookmarks.first.note, 'Great passage');

    store.updateColor(bm.id, HighlightColor.blue);
    expect(store.bookmarks.first.color, HighlightColor.blue);
  });

  test('query helpers filter correctly', () {
    // A position bookmark (no selected text)
    store.addBookmark(
      bookId: 'b1',
      chapterIndex: 0,
      chapterTitle: 'Ch 0',
    );
    // A highlight
    store.addBookmark(
      bookId: 'b1',
      chapterIndex: 1,
      chapterTitle: 'Ch 1',
      startChar: 10,
      endChar: 50,
      selectedText: 'Highlighted passage',
    );
    // Another book's bookmark
    store.addBookmark(
      bookId: 'b2',
      chapterIndex: 0,
      chapterTitle: 'Foreword',
    );

    expect(store.bookmarksForBook('b1').length, 2);
    expect(store.pageBookmarks('b1').length, 1);
    expect(store.highlights('b1').length, 1);
    expect(store.bookmarksForBook('b2').length, 1);
    expect(store.hasBookmark('b1', 0), true);
    expect(store.hasBookmark('b1', 1), false); // ch 1 only has a highlight
  });

  test('removeAll clears all bookmarks for a book', () {
    store.addBookmark(
      bookId: 'b1',
      chapterIndex: 0,
      chapterTitle: 'A',
    );
    store.addBookmark(
      bookId: 'b1',
      chapterIndex: 1,
      chapterTitle: 'B',
    );
    store.addBookmark(
      bookId: 'b2',
      chapterIndex: 0,
      chapterTitle: 'C',
    );

    store.removeAll('b1');
    expect(store.bookmarks.length, 1);
    expect(store.bookmarks.first.bookId, 'b2');
  });

  test('persistence survives reload', () async {
    store.addBookmark(
      bookId: 'b1',
      chapterIndex: 3,
      chapterTitle: 'Chapter 3',
      selectedText: 'important quote',
      note: 'Remember this',
      color: HighlightColor.green,
    );

    // Create a new store reading from the same prefs key.
    final prefs = await SharedPreferences.getInstance();
    final store2 = BookmarkStore(prefs: prefs, storageKey: 'bookmarks.test');
    expect(store2.bookmarks.length, 1);

    final restored = store2.bookmarks.first;
    expect(restored.bookId, 'b1');
    expect(restored.chapterIndex, 3);
    expect(restored.selectedText, 'important quote');
    expect(restored.note, 'Remember this');
    expect(restored.color, HighlightColor.green);
    expect(restored.isHighlight, true);
  });

  test('pruneOrphans drops bookmarks whose book is no longer in library', () {
    store.addBookmark(bookId: 'live-1', chapterIndex: 0, chapterTitle: 'A');
    store.addBookmark(bookId: 'live-1', chapterIndex: 1, chapterTitle: 'B');
    store.addBookmark(bookId: 'deleted-1', chapterIndex: 0, chapterTitle: 'C');
    store.addBookmark(bookId: 'deleted-2', chapterIndex: 0, chapterTitle: 'D');
    expect(store.bookmarks.length, 4);

    var notified = 0;
    store.addListener(() => notified++);

    final removed = store.pruneOrphans(['live-1']);

    expect(removed, 2);
    expect(store.bookmarks.length, 2);
    expect(store.bookmarks.every((b) => b.bookId == 'live-1'), true);
    expect(notified, 1);
  });

  test('pruneOrphans with all-valid ids is a no-op and does not notify', () {
    store.addBookmark(bookId: 'b1', chapterIndex: 0, chapterTitle: 'A');
    store.addBookmark(bookId: 'b2', chapterIndex: 0, chapterTitle: 'B');

    var notified = 0;
    store.addListener(() => notified++);

    final removed = store.pruneOrphans(['b1', 'b2', 'b3-unused']);
    expect(removed, 0);
    expect(store.bookmarks.length, 2);
    expect(notified, 0);
  });

  test('pruneOrphans persists across reload', () async {
    store.addBookmark(bookId: 'live-1', chapterIndex: 0, chapterTitle: 'A');
    store.addBookmark(bookId: 'gone-1', chapterIndex: 0, chapterTitle: 'B');

    store.pruneOrphans(['live-1']);

    final prefs = await SharedPreferences.getInstance();
    final store2 = BookmarkStore(prefs: prefs, storageKey: 'bookmarks.test');
    expect(store2.bookmarks.length, 1);
    expect(store2.bookmarks.first.bookId, 'live-1');
  });

  test('bookmarksForChapter orders by startChar', () {
    store.addBookmark(
      bookId: 'b1',
      chapterIndex: 0,
      chapterTitle: 'Ch',
      startChar: 100,
      endChar: 200,
      selectedText: 'second',
    );
    store.addBookmark(
      bookId: 'b1',
      chapterIndex: 0,
      chapterTitle: 'Ch',
      startChar: 10,
      endChar: 50,
      selectedText: 'first',
    );

    final chBms = store.bookmarksForChapter('b1', 0);
    expect(chBms.length, 2);
    expect(chBms[0].selectedText, 'first');
    expect(chBms[1].selectedText, 'second');
  });
}
