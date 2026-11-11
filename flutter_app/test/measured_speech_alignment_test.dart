import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/features/playback/measured_speech_alignment.dart';
import 'package:flutter_app/features/playback/measured_playback_binding.dart';
import 'package:flutter_app/services/fake_audio_player_service.dart';
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
}
