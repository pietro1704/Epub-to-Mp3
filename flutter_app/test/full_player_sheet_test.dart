import 'package:flutter/material.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/playback/audio_player_service.dart';

import 'support/fake_audio_player_service.dart';

import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/full_player_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _mockPrefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

Widget _wrap(
  SharedPreferences prefs,
  AudioPlayerInterface player, {
  String? bookTitle,
  String? author,
  String? chapterLabel,
  String? bookId,
}) {
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

bool isFilledButton(WidgetTester t, Finder finder) =>
    t.widget(finder) is FilledButton;

void main() {
  group('FullPlayerSheet', () {
    testWidgets('cover tap opens the reader at the playing chapter', (t) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService()..currentBookId = 'book-1';
      await player.setQueue([
        ChapterProgress(
          index: 1,
          name: 'Two',
          status: 'completed',
          downloadUrl: 'file:///a.mp3',
        ),
      ]);
      await t.pumpWidget(
        _wrap(prefs, player, bookTitle: 'Test Book', bookId: 'book-1'),
      );
      final container = ProviderScope.containerOf(
        t.element(find.byType(FullPlayerSheet)),
      );

      await t.tap(find.byKey(const ValueKey('fullPlayer.cover')));
      await t.pump();

      expect(container.read(readerPlaybackJumpProvider), (
        bookId: 'book-1',
        chapterIndex: 1,
      ));
      expect(container.read(currentlyReadingBookIdProvider), 'book-1');
      expect(container.read(appDestinationProvider), AppDestination.reader);
    });

    testWidgets(
      'the narrated-page button returns the reader to the spoken page and opens it at the playing chapter',
      (t) async {
        final prefs = await _mockPrefs();
        final player = FakeAudioPlayerService()..currentBookId = 'book-1';
        await player.setQueue([
          ChapterProgress(
            index: 3,
            name: 'Three',
            status: 'completed',
            downloadUrl: 'file:///a.mp3',
          ),
        ]);
        await t.pumpWidget(
          _wrap(prefs, player, bookTitle: 'Test Book', bookId: 'book-1'),
        );
        final container = ProviderScope.containerOf(
          t.element(find.byType(FullPlayerSheet)),
        );
        container.read(readerNarrationPairedProvider.notifier).state = false;
        await t.pump();

        final button = find.byKey(const ValueKey('fullPlayer.narratedPage'));
        expect(
          button,
          findsOneWidget,
          reason: 'the reader is not on the spoken page',
        );
        expect(
          isFilledButton(t, button),
          isTrue,
          reason: 'a Material FilledButton',
        );
        final before = container.read(readerPairRequestProvider);
        await t.tap(button);
        await t.pump();

        expect(container.read(readerPairRequestProvider), before + 1);
        expect(container.read(readerPlaybackJumpProvider), (
          bookId: 'book-1',
          chapterIndex: 3,
        ));
        expect(container.read(appDestinationProvider), AppDestination.reader);
      },
    );

    testWidgets(
      'the narrated-page button is hidden while the reader shows the spoken page',
      (t) async {
        final prefs = await _mockPrefs();
        final player = FakeAudioPlayerService()..currentBookId = 'book-1';
        await player.setQueue([
          ChapterProgress(
            index: 1,
            name: 'One',
            status: 'completed',
            downloadUrl: 'file:///a.mp3',
          ),
        ]);
        await t.pumpWidget(
          _wrap(prefs, player, bookTitle: 'Test Book', bookId: 'book-1'),
        );
        final container = ProviderScope.containerOf(
          t.element(find.byType(FullPlayerSheet)),
        );
        container.read(readerNarrationPairedProvider.notifier).state = true;
        await t.pump();
        expect(
          find.byKey(const ValueKey('fullPlayer.narratedPage')),
          findsNothing,
        );
        container.read(readerNarrationPairedProvider.notifier).state = false;
        await t.pump();
        expect(
          find.byKey(const ValueKey('fullPlayer.narratedPage')),
          findsOneWidget,
        );
      },
    );

    testWidgets('cover tap ignores a sheet whose book is not the one playing', (
      t,
    ) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService()..currentBookId = 'other-book';
      await player.setQueue([
        ChapterProgress(
          index: 1,
          name: 'One',
          status: 'completed',
          downloadUrl: 'file:///a.mp3',
        ),
      ]);
      await t.pumpWidget(
        _wrap(prefs, player, bookTitle: 'Test Book', bookId: 'book-1'),
      );
      final container = ProviderScope.containerOf(
        t.element(find.byType(FullPlayerSheet)),
      );

      await t.tap(find.byKey(const ValueKey('fullPlayer.cover')));
      await t.pump();

      expect(container.read(readerPlaybackJumpProvider), isNull);
      expect(container.read(currentlyReadingBookIdProvider), isNull);
    });

    testWidgets('renders with placeholder when no cover art', (t) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService();
      await t.pumpWidget(
        _wrap(
          prefs,
          player,
          bookTitle: 'Test Book',
          author: 'Test Author',
          chapterLabel: 'Chapter 1',
        ),
      );
      expect(find.text('Test Book'), findsOneWidget);
      expect(find.text('Test Author'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.byIcon(Icons.headphones), findsOneWidget);
      expect(find.byKey(const ValueKey('seek.forward.15')), findsOneWidget);
      expect(find.text('1.0x'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      player.dispose();
    });

    testWidgets('keeps book identity and close control visible', (t) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService();
      await t.pumpWidget(
        _wrap(prefs, player, bookTitle: 'Test Book', author: 'Test Author'),
      );

      expect(find.text('Test Book'), findsOneWidget);
      expect(find.text('Test Author'), findsOneWidget);
      expect(find.byKey(const ValueKey('fullPlayer.close')), findsOneWidget);
      await t.tap(find.byIcon(Icons.headphones));
      await t.pump();
      expect(find.text('Test Book'), findsOneWidget);
      expect(find.byKey(const ValueKey('fullPlayer.close')), findsOneWidget);
      player.dispose();
    });

    testWidgets('renders scrubber with time labels', (t) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService();
      await t.pumpWidget(_wrap(prefs, player));
      expect(find.text('0:00'), findsAtLeast(1));
      expect(find.byType(Slider), findsOneWidget);
      player.dispose();
    });

    testWidgets('shows play button when not playing', (t) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService();
      await t.pumpWidget(_wrap(prefs, player));
      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      player.dispose();
    });

    testWidgets('shows download button when chapters queued', (t) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService();
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
      final player = FakeAudioPlayerService();
      await t.pumpWidget(_wrap(prefs, player));
      expect(find.text('Save'), findsNothing);
      player.dispose();
    });

    testWidgets('shows chapter actions when the first queue arrives', (
      t,
    ) async {
      final prefs = await _mockPrefs();
      final player = FakeAudioPlayerService();
      addTearDown(player.dispose);
      await t.pumpWidget(_wrap(prefs, player));
      expect(find.text('Chapters'), findsNothing);
      expect(find.text('Save'), findsNothing);

      await player.setQueue([
        const ChapterProgress(index: 0, name: 'First chapter'),
      ]);
      await t.pump();
      expect(find.text('Chapters'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });
  });
}
