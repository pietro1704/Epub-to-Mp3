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
    test('opening a book never moves it to the front', () {
      final a = _book('a', t0, played: t0.add(const Duration(days: 3)));
      final b = _book('b', t0.add(const Duration(days: 1)));
      final c = _book('c', t0.add(const Duration(days: 2)));
      // The user opens (reads or starts listening to) c just now.
      c.lastOpenedAt = t0.add(const Duration(days: 9));
      expect(sortBooksByRecentPlayback([b, c, a]).map((x) => x.id), ['a', 'c', 'b']);
    });

    test('played books come first by last playback, the rest keep newest-added first', () {
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

    test('openBookFile does not touch playback recency', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = LibraryStore(prefs: prefs);
      final dir = await Directory.systemTemp.createTemp('recent_playback_');
      final file = File('${dir.path}/x.epub')..writeAsBytesSync(List.filled(40, 7));
      final book = await store.importBook(file.path);
      await store.openBookFile(book.id);
      expect(store.books.single.lastPlayedAt, isNull);
      store.recordPlayback(book.id);
      expect(store.books.single.lastPlayedAt, isNotNull);
      expect(LibraryStore(prefs: prefs).books.single.lastPlayedAt, isNotNull, reason: 'persisted');
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
