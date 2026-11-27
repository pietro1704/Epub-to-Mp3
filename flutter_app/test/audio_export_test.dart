import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/conversion/audio_export.dart';

void main() {
  test('only finished MP3 chapters can be exported', () {
    final list = mp3ExportChapters(const [
      AudioExportChapter(title: 'A', path: '/a/1.mp3'),
      AudioExportChapter(title: 'B', path: '/a/2.wav'),
      AudioExportChapter(title: 'C', path: '/a/3.MP3'),
    ]);
    expect(list.map((c) => c.title), ['A', 'C']);
  });

  test('the request names the layout and chapters Rust expects', () async {
    String? sent;
    final exporter = AudioExporter(
      call: (request) async {
        sent = request;
        return jsonEncode({
          'files': ['/out/01 - A.mp3'],
        });
      },
    );
    final files = await exporter.export(
      destination: '/out',
      layout: AudioExportLayout.perChapter,
      title: 'Hamlet',
      chapters: const [AudioExportChapter(title: 'A', path: '/a/1.mp3')],
    );
    expect(files, ['/out/01 - A.mp3']);
    final map = jsonDecode(sent!) as Map;
    expect(map['layout'], 'perChapter');
    expect(map['destination'], '/out');
    expect(map.containsKey('author'), isFalse);
    expect((map['chapters'] as List).single, {
      'title': 'A',
      'path': '/a/1.mp3',
    });
  });

  test('a refused export surfaces as an exception', () async {
    final exporter = AudioExporter(call: (_) async => null);
    expect(
      exporter.export(
        destination: '/out',
        layout: AudioExportLayout.single,
        title: 'x',
        chapters: const [],
      ),
      throwsA(isA<AudioExportException>()),
    );
  });
}
