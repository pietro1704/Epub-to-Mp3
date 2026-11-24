// CONTRAST-AUDIT, area 3: the player (mini bar and expanded sheet) in light, dark and both
// Increase Contrast variants, measured on the rendered pixels.
import 'package:flutter/material.dart';
import 'package:flutter_app/design_system/app_theme.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/full_player_sheet.dart';
import 'package:flutter_app/views/mini_player_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contrast_audit.dart';
import 'support/fake_audio_player_service.dart';

Future<List<ContrastFinding>> _audit(
  WidgetTester tester,
  Brightness brightness,
  bool highContrast,
  Widget Function(FakeAudioPlayerService player) screen,
) async {
  final book = BookEntity(
    id: 'book1',
    title: 'Playing Book',
    author: 'Author A',
    filePath: '/tmp/book.epub',
    displayFilename: 'book.epub',
    addedAt: DateTime(2025, 1, 1),
  );
  SharedPreferences.setMockInitialValues({
    'library.books.v1': '[${book.encode()}]',
  });
  final prefs = await SharedPreferences.getInstance();
  final player = FakeAudioPlayerService()..currentBookId = 'book1';
  await player.setQueue([
    const ChapterProgress(
      index: 0,
      name: 'Opening Chapter',
      status: 'completed',
      downloadUrl: 'file:///a.mp3',
    ),
    const ChapterProgress(
      index: 1,
      name: 'Second Chapter',
      status: 'completed',
      downloadUrl: 'file:///b.mp3',
    ),
  ]);
  final key = GlobalKey();
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AuditHost(
      boundaryKey: key,
      child: ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          currentlyPlayingBookIdProvider.overrideWith((ref) => 'book1'),
          globalAudioPlayerProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          theme: AppTheme.forBrightness(brightness, highContrast: highContrast),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: screen(player)),
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return auditContrast(tester, key);
}

void main() {
  final screens = <String, Widget Function(FakeAudioPlayerService)>{
    'Mini player': (_) =>
        const Align(alignment: Alignment.bottomCenter, child: MiniPlayerBar()),
    'Expanded player': (player) => FullPlayerSheet(
      player: player,
      bookTitle: 'Playing Book',
      author: 'Author A',
      chapterLabel: 'Opening Chapter',
      bookId: 'book1',
    ),
  };
  for (final entry in screens.entries) {
    for (final brightness in Brightness.values) {
      for (final highContrast in [false, true]) {
        final mode =
            '${brightness.name}${highContrast ? ' + Increase Contrast' : ''}';
        testWidgets(
          '${entry.key}: every text and icon meets WCAG AA in $mode',
          (tester) async {
            final findings = await _audit(
              tester,
              brightness,
              highContrast,
              entry.value,
            );
            expect(findings, isEmpty, reason: findings.join('\n'));
          },
        );
      }
    }
  }
}
