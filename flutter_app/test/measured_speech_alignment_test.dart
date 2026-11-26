import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/features/playback/measured_speech_alignment.dart';
import 'package:flutter_app/features/playback/measured_playback_binding.dart';

import 'support/fake_audio_player_service.dart';

import 'package:flutter_app/models/job_snapshot.dart';

Uint8List tag(List<Object> passages, {int version = 3}) {
  final payload = [
    ...ascii.encode(MeasuredSpeechAlignment.owner),
    0,
    ...utf8.encode(jsonEncode(passages)),
  ];
  List<int> size(int count, bool safe) => [
    for (final shift in (safe ? [21, 14, 7, 0] : [24, 16, 8, 0]))
      (count >> shift) & (safe ? 127 : 255),
  ];
  final frame = [
    ...ascii.encode('PRIV'),
    ...size(payload.length, version == 4),
    0,
    0,
    ...payload,
  ];
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    version,
    0,
    0,
    ...size(frame.length, true),
    ...frame,
  ]);
}

Map<String, Object> passage({int? offset}) => {
  'version': 1,
  'text': 'Ação 🐧',
  'audioStart': 2,
  'sourceOffset': ?offset,
  'words': [
    {'location': 0, 'length': 4, 'start': 0, 'end': .5},
    {'location': 5, 'length': 2, 'start': .5, 'end': 1},
  ],
};

class ItemPlayer extends FakeAudioPlayerService {
  Uri? item;
  @override
  Uri? get currentAudioUri => item;
}

void main() {
  for (final version in [3, 4]) {
    test(
      'ID3 v2.$version uses measured media time and valid Unicode boundaries',
      () {
        final alignment = MeasuredSpeechAlignment.parse(
          tag([passage()], version: version),
        );
        expect(
          alignment.rangeAt(2.7, 'Ação 🐧'),
          const TextRange(start: 5, end: 7),
        );
        expect(alignment.rangeAt(1.9, 'Ação 🐧'), isNull);
        expect(alignment.rangeAt(3, 'Ação 🐧'), isNull);
        expect(alignment.rangeAt(2.7, 'Different book'), isNull);
      },
    );
  }
  test('repeated passages require a source occurrence and preserve whitespace mapping', () {
    const source = 'Ação 🐧  Ação 🐧';
    expect(
      MeasuredSpeechAlignment.parse(tag([passage()])).rangeAt(2.2, source),
      isNull,
    );
    final alignment = MeasuredSpeechAlignment.parse(tag([passage(offset: 8)]));
    expect(alignment.rangeAt(2.2, source), const TextRange(start: 9, end: 13));
  });
  test(
    'malformed metadata and broken surrogate ranges produce no highlight',
    () {
      final broken = passage();
      broken['words'] = [
        {'location': 5, 'length': 1, 'start': 0, 'end': 1},
      ];
      expect(
        MeasuredSpeechAlignment.parse(tag([broken])).rangeAt(2.2, 'Ação 🐧'),
        isNull,
      );
      final bytes = tag([passage()]);
      expect(
        MeasuredSpeechAlignment.parse(bytes.sublist(0, 15)).passages,
        isEmpty,
      );
      expect(MeasuredSpeechAlignment.parse(Uint8List(0)).passages, isEmpty);
    },
  );
  test(
    'late reads never publish for an older media item or another book',
    () async {
      final player = ItemPlayer()
        ..item = Uri.file('/first.mp3')
        ..currentBookId = 'book';
      await player.setQueue([
        const ChapterProgress(index: 7, name: 'Seven', status: 'completed'),
      ]);
      await player.play(); // a passage is painted only for narration that has played
      final first = Completer<MeasuredSpeechAlignment>();
      final second = Completer<MeasuredSpeechAlignment>();
      final binding = MeasuredPlaybackBinding(
        player: player,
        bookId: 'book',
        chapterIndex: 7,
        source: 'Ação 🐧',
        read: (uri) => uri.path == '/first.mp3' ? first.future : second.future,
      );
      final changes = <TextRange?>[];
      final subscription = binding.changes.listen(changes.add);
      binding.update(2.7);
      player.item = Uri.file('/second.mp3');
      binding.update(2.7);
      first.complete(MeasuredSpeechAlignment.parse(tag([passage()])));
      await Future<void>.delayed(Duration.zero);
      expect(changes.whereType<TextRange>(), isEmpty);
      await player.seek(const Duration(milliseconds: 2700));
      second.complete(MeasuredSpeechAlignment.parse(tag([passage()])));
      await Future<void>.delayed(Duration.zero);
      expect(changes.last, const TextRange(start: 5, end: 7));
      player.currentBookId = 'other';
      binding.update(2.7);
      await Future<void>.delayed(Duration.zero);
      expect(changes.last, isNull);
      await binding.dispose();
      await subscription.cancel();
      await player.dispose();
    },
  );

  group('narrated footnotes', () {
    // Chapter text; the note body "Corpo da nota." is scalars 24..38 and is read at the reference.
    const chapter = 'Texto antes 1 e depois. Corpo da nota.';
    Map<String, Object> sourcePassage(
      String text,
      int offset,
      double audioStart,
    ) => {
      'version': 1,
      'text': text,
      'audioStart': audioStart,
      'sourceOffset': offset,
      'words': [
        {'location': 0, 'length': text.length, 'start': 0, 'end': 1},
      ],
    };
    Map<String, Object> notePassage({required int start, required int end}) => {
      'version': 1,
      'text':
          'Início da nota de rodapé 1. Corpo da nota. Fim da nota de rodapé 1.',
      'audioStart': 3,
      'note': {'number': '1', 'sourceStart': start, 'sourceEnd': end},
      'words': [
        {'location': 0, 'length': 6, 'start': 0, 'end': 1},
        {'location': 28, 'length': 5, 'start': 1, 'end': 2},
        {'location': 43, 'length': 3, 'start': 2, 'end': 4},
      ],
    };

    test('the body is highlighted while the note is read and the text resumes after it', () {
      final alignment = MeasuredSpeechAlignment.parse(
        tag([
          sourcePassage('Texto antes 1', 0, 0),
          notePassage(start: 24, end: 38),
          sourcePassage('e depois.', 14, 8),
        ]),
      );
      expect(
        alignment.rangeAt(.5, chapter),
        const TextRange(start: 0, end: 13),
      );
      for (final seconds in [3.2, 4.5, 6.5]) {
        expect(
          alignment.rangeAt(seconds, chapter),
          const TextRange(start: 24, end: 38),
          reason: 'second $seconds of the spoken note',
        );
      }
      expect(
        alignment.rangeAt(8.5, chapter),
        const TextRange(start: 14, end: 23),
      );
    });

    test('a note whose body is elsewhere keeps the reference highlighted', () {
      final alignment = MeasuredSpeechAlignment.parse(
        tag([notePassage(start: 13, end: 13)]),
      );
      expect(
        alignment.rangeAt(4, chapter),
        const TextRange(start: 12, end: 13),
      );
    });

    test('an invalid note range produces no highlight', () {
      for (final range in [(40, 50), (30, 24)]) {
        expect(
          MeasuredSpeechAlignment.parse(
            tag([notePassage(start: range.$1, end: range.$2)]),
          ).rangeAt(4, chapter),
          isNull,
        );
      }
    });
  });

  // Parity with the Apple reader (#1636): the narrated passage stays painted while paused and goes
  // only on a jump or seek (the book/chapter change and follow-audio-off cases are covered above).
  group('highlight while paused', () {
    Future<(ItemPlayer, MeasuredPlaybackBinding, List<TextRange?>)> rig() async {
      final player = ItemPlayer()
        ..item = Uri.file('/a.mp3')
        ..currentBookId = 'book';
      await player.setQueue([
        const ChapterProgress(index: 7, name: 'Seven', status: 'completed'),
      ]);
      final binding = MeasuredPlaybackBinding(
        player: player,
        bookId: 'book',
        chapterIndex: 7,
        source: 'Ação 🐧',
        read: (_) async => MeasuredSpeechAlignment.parse(tag([passage()])),
      );
      final changes = <TextRange?>[];
      binding.changes.listen(changes.add);
      binding.update(2.2);
      await Future<void>.delayed(Duration.zero);
      return (player, binding, changes);
    }

    test('pausing keeps the narrated passage painted', () async {
      final (player, binding, changes) = await rig();
      await player.play();
      await player.seek(const Duration(milliseconds: 2200));
      await Future<void>.delayed(Duration.zero);
      expect(changes.last, const TextRange(start: 0, end: 4));
      await player.pause();
      await Future<void>.delayed(Duration.zero);
      expect(changes.last, const TextRange(start: 0, end: 4));
      await binding.dispose();
    });

    test('a seek while paused clears it, and playing again paints the new place', () async {
      final (player, binding, changes) = await rig();
      await player.play();
      await player.seek(const Duration(milliseconds: 2200));
      await player.pause();
      await Future<void>.delayed(Duration.zero);
      await player.seek(const Duration(milliseconds: 2700));
      await Future<void>.delayed(Duration.zero);
      expect(changes.last, isNull);
      await player.play();
      await Future<void>.delayed(Duration.zero);
      expect(changes.last, const TextRange(start: 5, end: 7));
      await binding.dispose();
    });

    test('a book that was never narrated shows no passage while paused', () async {
      final (player, binding, changes) = await rig();
      await player.seek(const Duration(milliseconds: 2200));
      await Future<void>.delayed(Duration.zero);
      expect(changes.whereType<TextRange>(), isEmpty);
      await binding.dispose();
    });
  });
}
