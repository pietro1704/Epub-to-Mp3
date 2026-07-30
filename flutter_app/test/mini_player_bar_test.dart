import 'package:flutter/material.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/audio_player_service.dart';
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
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
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
