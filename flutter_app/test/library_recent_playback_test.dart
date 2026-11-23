import 'dart:io';

import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/screens/library_screen.dart' show sortBooksByRecentPlayback;
import 'package:flutter_app/services/playback/playback_recency_recorder.dart';
import 'package:flutter_app/services/storage/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio_player_service.dart';

BookEntity _book(String id, DateTime added, {DateTime? opened, DateTime? played}) => BookEntity(
  id: id,
  title: id,
  filePath: '/tmp/$id.epub',
  displayFilename: '$id.epub',
  addedAt: added,
  lastOpenedAt: opened,
  lastPlayedAt: played,
);

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime(2026, 11, 1);

  group('Recently played order', () {
    test('opening a book (to read or to listen) puts it first at once, with no audio played', () {
      final a = _book('a', t0, played: t0.add(const Duration(days: 3)));
      final b = _book('b', t0.add(const Duration(days: 1)));
      final c = _book('c', t0.add(const Duration(days: 2)));
      // The user opens b just now: reading, or starting to listen. No audio is heard.
      b.lastOpenedAt = t0.add(const Duration(days: 9));
      expect(sortBooksByRecentPlayback([a, b, c]).map((x) => x.id), ['b', 'a', 'c']);
      // Then c is opened: it takes the first place.
      c.lastOpenedAt = t0.add(const Duration(days: 10));
      expect(sortBooksByRecentPlayback([a, b, c]).map((x) => x.id), ['c', 'b', 'a']);
    });

    test('the latest of opened and played decides: playing later moves a book ahead of one only opened', () {
      final opened = _book('opened', t0, opened: t0.add(const Duration(days: 5)));
      final played = _book('played', t0.add(const Duration(days: 1)), played: t0.add(const Duration(days: 6)));
      expect(sortBooksByRecentPlayback([opened, played]).map((x) => x.id), ['played', 'opened']);
      opened.lastOpenedAt = t0.add(const Duration(days: 7));
      expect(sortBooksByRecentPlayback([opened, played]).map((x) => x.id), ['opened', 'played']);
    });

    test('books never opened or played keep newest-added first, after the ones with activity', () {
      final old = _book('old', t0, played: t0.add(const Duration(days: 5)));
      final recent = _book('recent', t0.add(const Duration(days: 1)), played: t0.add(const Duration(days: 6)));
      final newUnplayed = _book('new', t0.add(const Duration(days: 8)));
      final olderUnplayed = _book('older', t0.add(const Duration(days: 2)));
      expect(
        sortBooksByRecentPlayback([olderUnplayed, old, newUnplayed, recent]).map((x) => x.id),
        ['recent', 'old', 'new', 'older'],
      );
    });

    test('lastPlayedAt survives a JSON round trip', () {
      final book = _book('a', t0, played: t0.add(const Duration(days: 1)));
      expect(BookEntity.fromJson(book.toJson()).lastPlayedAt, book.lastPlayedAt);
      expect(BookEntity.fromJson(_book('b', t0).toJson()).lastPlayedAt, isNull);
    });

    test('openBookFile puts the book first right away, before any audio; playing keeps it there', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      final dir = await Directory.systemTemp.createTemp('recent_open_');
      final first = File('${dir.path}/a.epub')..writeAsBytesSync(List.filled(40, 7));
      final second = File('${dir.path}/b.epub')..writeAsBytesSync(List.filled(40, 9));
      final a = await store.importBook(first.path);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final b = await store.importBook(second.path);
      expect(sortBooksByRecentPlayback(store.books).first.id, b.id, reason: 'b was added last');

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.openBookFile(a.id);
      expect(sortBooksByRecentPlayback(store.books).first.id, a.id, reason: 'opening a (no audio) moves it to the front');
      expect(store.books.firstWhere((x) => x.id == a.id).lastPlayedAt, isNull);

      await Future<void>.delayed(const Duration(milliseconds: 5));
      store.recordPlayback(b.id);
      expect(sortBooksByRecentPlayback(store.books).first.id, b.id, reason: 'playing b afterwards moves it to the front');
      expect(LibraryStore(prefs: prefs).books.firstWhere((x) => x.id == b.id).lastPlayedAt, isNotNull, reason: 'persisted');
    });
  });

  group('PlaybackRecencyRecorder', () {
    test('records when audio becomes audible, once per play, and again after a pause or another book', () async {
      final player = FakeAudioPlayerService();
      var current = 'a';
      final played = <String>[];
      final recorder = PlaybackRecencyRecorder(player: player, bookId: () => current, onPlayed: played.add);
      addTearDown(recorder.dispose);

      await player.seek(const Duration(seconds: 1));
      await _tick();
      expect(played, isEmpty, reason: 'a position without playback is not audible');

      await player.play();
      await player.seek(const Duration(seconds: 2));
      await player.seek(const Duration(seconds: 3));
      await _tick();
      expect(played, ['a']);

      await player.pause();
      await player.play();
      await player.seek(const Duration(seconds: 4));
      await _tick();
      expect(played, ['a', 'a'], reason: 'resumed playback counts again');

      current = 'b';
      await player.seek(const Duration(seconds: 5));
      await _tick();
      expect(played, ['a', 'a', 'b']);
    });
  });
}
