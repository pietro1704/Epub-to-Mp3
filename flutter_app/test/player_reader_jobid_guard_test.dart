// Slice 44 — Flutter mirror of iOS slice 43 defense-in-depth.
//
// Guards `PlayerReaderScreen` against a parent feeding a new jobId
// without recreating the State (e.g., a future router that reuses the
// same widget key across jobs). The screen owns three StreamSubscriptions
// (`_chapterIndexSub`, `_playingSub`, `_positionSub`) plus a
// `SentenceSyncCoordinator` keyed to `audioPlayerProvider(jobId)`. If
// the jobId mutates in place, stale subs would keep driving setState
// from the previous job's player.
//
// Today every call site pushes a fresh route per jobId so the path is
// dormant; the test pins the invariant to the source so it fails loud
// the day a caller forgets the identity key.
//
// Content-based rather than widget-driven because exercising the real
// rebuild would require overriding ~8 providers (audioPlayer, jobStream,
// jobSnapshot, fulltext, syncEngine, bookmarkStore, settings,
// downloadManager) — the iOS slice took the same shortcut and the
// invariant is structural, not behavioural.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source =
      File('lib/screens/player_reader_screen.dart').readAsStringSync();

  group('PlayerReaderScreen jobId guard', () {
    test('declares didUpdateWidget covariant override', () {
      expect(
        source.contains(
            'void didUpdateWidget(covariant PlayerReaderScreen oldWidget)'),
        isTrue,
        reason: 'didUpdateWidget must exist so a mid-mount jobId change is '
            'detected — see slice 44 / iOS slice 43.',
      );
    });

    test('teardown helper exists and clears all four lifecycle handles',
        () {
      final start = source.indexOf('void _tearDownPlayerSubscriptions()');
      expect(start, isNonNegative,
          reason: 'Need a single teardown helper shared by dispose + '
              'didUpdateWidget so the order cannot drift between them.');
      final end = source.indexOf('\n  }\n', start);
      expect(end, isNonNegative);
      final body = source.substring(start, end);
      for (final handle in const [
        '_chapterIndexSub',
        '_playingSub',
        '_positionSub',
        '_sentenceSync',
      ]) {
        expect(body.contains(handle), isTrue,
            reason: '$handle must be released by the teardown helper.');
      }
      // Subscriptions must be nulled out — a stale .cancel() on a
      // non-null handle would still let the next teardown double-cancel.
      expect(body.contains('_chapterIndexSub = null'), isTrue);
      expect(body.contains('_playingSub = null'), isTrue);
      expect(body.contains('_positionSub = null'), isTrue);
      expect(body.contains('_sentenceSync = null'), isTrue);
    });

    test('didUpdateWidget tears down before re-subscribing', () {
      final didUpdateStart =
          source.indexOf('void didUpdateWidget(covariant PlayerReaderScreen');
      expect(didUpdateStart, isNonNegative);
      // Find the matching closing brace by counting braces.
      final openBrace = source.indexOf('{', didUpdateStart);
      var depth = 0;
      var i = openBrace;
      while (i < source.length) {
        final c = source[i];
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) break;
        }
        i++;
      }
      expect(depth, 0, reason: 'Balanced-brace extraction must terminate.');
      final body = source.substring(openBrace, i + 1);

      final tearIdx = body.indexOf('_tearDownPlayerSubscriptions()');
      final subIdx = body.indexOf('_subscribeToPlayer()');
      expect(tearIdx, isNonNegative,
          reason: 'didUpdateWidget must call teardown.');
      expect(subIdx, isNonNegative,
          reason: 'didUpdateWidget must re-bootstrap after teardown.');
      expect(tearIdx < subIdx, isTrue,
          reason: 'Teardown must precede re-subscription so the new player '
              'is not driven by the previous job\'s callbacks for one frame.');

      // Local UI state that follows the player must reset too —
      // otherwise the new job inherits the previous chapter cursor.
      expect(body.contains('_currentChapterIndex = 0'), isTrue);
      expect(body.contains('_isPlaying = false'), isTrue);
    });

    test('jobId change is the only trigger', () {
      expect(source.contains('oldWidget.jobId != widget.jobId'), isTrue,
          reason: 'Guard must key on jobId; any other field would cause '
              'spurious teardowns on benign rebuilds.');
    });

    test('dispose delegates to the same teardown helper', () {
      final disposeStart = source.indexOf('void dispose()');
      expect(disposeStart, isNonNegative);
      final disposeEnd = source.indexOf('super.dispose();', disposeStart);
      expect(disposeEnd, isNonNegative);
      final body = source.substring(disposeStart, disposeEnd);
      expect(body.contains('_tearDownPlayerSubscriptions()'), isTrue,
          reason: 'dispose must reuse teardown so the cleanup path stays '
              'single-sourced.');
    });
  });
}
