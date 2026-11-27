import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'support/fake_audio_player_service.dart';
import 'package:flutter_app/services/cover_decoder.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/mini_player_bar.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _mockPrefs([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? {});
  return SharedPreferences.getInstance();
}

void main() {
  test('does not expose MIME metadata as a chapter title', () {
    const chapter = FulltextChapter(
      index: 0,
      name: 'Application/xhtml+xml',
      text: 'Conteúdo real',
    );
    expect(chapter.displayTitle, 'Chapter 0');
  });

  group('MiniPlayerBar', () {
    testWidgets('hidden when no book is playing', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(
        ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: const MaterialApp(home: Scaffold(body: MiniPlayerBar())),
        ),
      );
      await t.pump();

      // SizedBox.shrink renders nothing visible.
      expect(find.byType(MiniPlayerBar), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
    });

    testWidgets('shows when book is playing', (t) async {
      final book = BookEntity(
        id: 'book1',
        title: 'Playing Book',
        author: 'Author A',
        filePath: '/tmp/book.epub',
        displayFilename: 'book.epub',
        addedAt: DateTime(2025, 1, 1),
      );
      final booksJson = '[${book.encode()}]';
      final prefs = await _mockPrefs({'library.books.v1': booksJson});
      final fake = FakeAudioPlayerService();
      await fake.setQueue([
        const ChapterProgress(index: 0, name: 'Opening Chapter'),
      ]);

      await t.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            currentlyPlayingBookIdProvider.overrideWith((ref) => 'book1'),
            globalAudioPlayerProvider.overrideWithValue(fake),
          ],
          child: const MaterialApp(home: Scaffold(body: MiniPlayerBar())),
        ),
      );
      await t.pump();

      expect(find.text('Opening Chapter'), findsOneWidget);
      expect(find.text('Playing Book'), findsOneWidget);
      expect(find.text('Author A'), findsNothing);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('seek.forward.15')), findsOneWidget);
    });

    testWidgets('player ticks decode the book cover once', (t) async {
      // 1x1 transparent PNG.
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      final book = BookEntity(
        id: 'book1',
        title: 'Playing Book',
        author: 'Author A',
        filePath: '/tmp/book.epub',
        displayFilename: 'book.epub',
        addedAt: DateTime(2025, 1, 1),
        coverBase64: png,
      );
      final prefs = await _mockPrefs({'library.books.v1': '[${book.encode()}]'});
      final fake = FakeAudioPlayerService();
      await fake.setQueue([
        const ChapterProgress(index: 0, name: 'Opening Chapter'),
      ]);
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            currentlyPlayingBookIdProvider.overrideWith((ref) => 'book1'),
            globalAudioPlayerProvider.overrideWithValue(fake),
          ],
          child: const MaterialApp(home: Scaffold(body: MiniPlayerBar())),
        ),
      );
      await t.pump();
      CoverDecoder.decodeCalls = 0;
      for (var i = 0; i < 10; i++) {
        await (i.isEven ? fake.play() : fake.pause());
        await t.pump();
      }
      expect(CoverDecoder.decodeCalls, lessThanOrEqualTo(1));
    });

    testWidgets('finishing the initial conversion keeps a later pause', (
      tester,
    ) async {
      final book = BookEntity(
        id: 'book1',
        title: 'Playing Book',
        author: 'Author A',
        filePath: '/tmp/book.epub',
        displayFilename: 'book.epub',
        addedAt: DateTime(2025, 1, 1),
      );
      final prefs = await _mockPrefs({'library.books.v1': '[${book.encode()}]'});
      final player = FakeAudioPlayerService();
      final conversion = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            currentlyPlayingBookIdProvider.overrideWith((ref) => book.id),
            globalAudioPlayerProvider.overrideWithValue(player),
            playbackRequestProvider.overrideWith((ref) => () async {
              await player.setQueue([
                const ChapterProgress(index: 0, name: 'Opening Chapter'),
              ]);
              await player.play();
              await conversion.future;
            }),
          ],
          child: const MaterialApp(home: Scaffold(body: MiniPlayerBar())),
        ),
      );

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(player.isPlaying, isTrue);
      await player.pause();
      await tester.pump();

      conversion.complete();
      await tester.pump();
      expect(player.isPlaying, isFalse);
    });

    testWidgets('hidden when playing book not in library', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            currentlyPlayingBookIdProvider.overrideWith((ref) => 'missing'),
          ],
          child: const MaterialApp(home: Scaffold(body: MiniPlayerBar())),
        ),
      );
      await t.pump();

      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

  });
}
