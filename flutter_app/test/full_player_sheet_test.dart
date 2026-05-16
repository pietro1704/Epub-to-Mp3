import 'package:flutter/material.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/full_player_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _mockPrefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs, AudioPlayerService player,
    {String? bookTitle,
    String? author,
    String? chapterLabel,
    String? bookId}) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      home: Scaffold(
        body: FullPlayerSheet(
          player: player,
          bookTitle: bookTitle,
          author: author,
          chapterLabel: chapterLabel,
          bookId: bookId,
        ),
      ),
    ),
  );
}

void main() {
  group('FullPlayerSheet', () {
    testWidgets('renders with placeholder when no cover art', (t) async {
      final prefs = await _mockPrefs();
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await t.pumpWidget(_wrap(prefs, player,
          bookTitle: 'Test Book',
          author: 'Test Author',
          chapterLabel: 'Chapter 1'));
      expect(find.text('Test Book'), findsOneWidget);
      expect(find.text('Test Author'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.byIcon(Icons.headphones), findsOneWidget);
      expect(find.byIcon(Icons.forward_30), findsOneWidget);
      expect(find.text('1.0x'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      player.dispose();
    });

    testWidgets('renders scrubber with time labels', (t) async {
      final prefs = await _mockPrefs();
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await t.pumpWidget(_wrap(prefs, player));
      expect(find.text('0:00'), findsAtLeast(1));
      expect(find.byType(Slider), findsOneWidget);
      player.dispose();
    });

    testWidgets('shows play button when not playing', (t) async {
      final prefs = await _mockPrefs();
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await t.pumpWidget(_wrap(prefs, player));
      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      player.dispose();
    });

    testWidgets('shows download button when chapters queued', (t) async {
      final prefs = await _mockPrefs();
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await player.setQueue([
        const ChapterProgress(
          index: 0,
          name: 'Ch 1',
          status: 'completed',
          downloadUrl: 'http://test/ch0.mp3',
        ),
      ]);
      await t.pumpWidget(_wrap(prefs, player, bookId: 'test-book'));
      expect(find.text('Save'), findsOneWidget);
      expect(find.byIcon(Icons.download_rounded), findsOneWidget);
      player.dispose();
    });

    testWidgets('hides download button when no chapters', (t) async {
      final prefs = await _mockPrefs();
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await t.pumpWidget(_wrap(prefs, player));
      expect(find.text('Save'), findsNothing);
      player.dispose();
    });
  });
}
