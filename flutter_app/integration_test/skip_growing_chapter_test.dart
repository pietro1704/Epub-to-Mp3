// Real-synthesis regression for "skip 15 s while the chapter is still being
// synthesized" (Pietro: it can load forever). Run on Linux with a converter
// library and a Piper model (see docs): it plays a long Portuguese book and taps
// "forward 15 s" six times (90 s) while chapter 1 is still growing.
//
//   EVIDENCE_BOOK=/path/Longo.epub EPUB2MP3_CONVERTER_FFI=... \
//   flutter test integration_test/skip_growing_chapter_test.dart -d linux
//
// Expected: the skip is honored within seconds by restarting synthesis at the
// estimated text position, so the playing audio's duration falls back to a small
// value (a new, short growing source). Before the fix the taps waited for the
// whole chapter to finish (~45 s) and replaced each other.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/main.dart' as app;
import 'package:flutter_app/screens/library_screen.dart' show libraryStoreProvider;
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_narration_menu.dart' show installedNarrationModelIdsProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('skipping forward over a growing chapter restarts synthesis promptly', (tester) async {
    final book = Platform.environment['EVIDENCE_BOOK'];
    if (book == null) fail('Set EVIDENCE_BOOK to a long Portuguese EPUB');
    app.main();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    final converter = container.read(embeddedConverterProvider);
    final root = await container.read(ttsModelRootProvider.future);
    await tester.runAsync(() async {
      await for (final _ in converter.installTtsModelWithProgress(modelId: 'pt_BR-faber-medium', root: root)) {}
    });
    container.invalidate(installedNarrationModelIdsProvider);
    await container.read(libraryStoreProvider).importBook(book);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.textContaining('Casa na Colina').first);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    final player = container.read(globalAudioPlayerProvider);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    var waited = 0;
    while (!player.isPlaying && waited < 240) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      waited++;
    }
    expect(player.isPlaying, isTrue, reason: 'playback must start');
    // Let the chapter grow for a while, but skip while it is still synthesizing.
    var grown = 0;
    while (player.durationSeconds < 30 && grown < 90) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      grown++;
    }
    final durationBefore = player.durationSeconds;
    expect(durationBefore, greaterThan(20), reason: 'the chapter is growing');

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const ValueKey('seek.forward.15')).first);
      await tester.pump(const Duration(milliseconds: 150));
    }
    // Let the skip taps' accumulation window elapse (test time is fake).
    await tester.pump(const Duration(seconds: 1));

    // Within 15 s the skip must have been honored: synthesis restarted, so the
    // audio now playing is a fresh, short source.
    var restarted = false;
    for (var i = 0; i < 15 && !restarted; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump();
      final duration = player.durationSeconds;
      if (duration > 0 && duration < durationBefore - 15) restarted = true;
    }
    expect(restarted, isTrue,
        reason: 'the +90 s skip over a still-growing chapter must restart synthesis within 15 s, not wait for the chapter to finish');
    expect(player.isPlaying || player.isLoading, isTrue);
  });
}
