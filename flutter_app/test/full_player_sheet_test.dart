import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/audio_player_service.dart';
import 'package:flutter_app/views/full_player_sheet.dart';

void main() {
  group('FullPlayerSheet', () {
    testWidgets('renders with placeholder when no cover art', (t) async {
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FullPlayerSheet(
            player: player,
            bookTitle: 'Test Book',
            author: 'Test Author',
            chapterLabel: 'Chapter 1',
          ),
        ),
      ));
      expect(find.text('Test Book'), findsOneWidget);
      expect(find.text('Test Author'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.byIcon(Icons.headphones), findsOneWidget);
      // Transport buttons
      expect(find.byIcon(Icons.replay_10), findsOneWidget);
      expect(find.byIcon(Icons.forward_10), findsOneWidget);
      // Speed and sleep
      expect(find.text('1.0x'), findsOneWidget);
      expect(find.text('Sleep'), findsOneWidget);
      player.dispose();
    });

    testWidgets('renders scrubber with time labels', (t) async {
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FullPlayerSheet(player: player),
        ),
      ));
      expect(find.text('0:00'), findsAtLeast(1));
      expect(find.byType(Slider), findsOneWidget);
      player.dispose();
    });

    testWidgets('shows play button when not playing', (t) async {
      final player = AudioPlayerService(backendBase: 'http://localhost:8000');
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FullPlayerSheet(player: player),
        ),
      ));
      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      player.dispose();
    });
  });
}
