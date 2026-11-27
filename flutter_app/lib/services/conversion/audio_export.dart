import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'desktop_embedded_converter.dart';

enum AudioExportLayout { single, perChapter }

class AudioExportChapter {
  const AudioExportChapter({required this.title, required this.path});
  final String title;
  final String path;
}

class AudioExportException implements Exception {
  const AudioExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Chapters whose audio Rust can export: finished MP3 files only. Piper writes MP3; system and
/// other voices may not, and then the export is unavailable (the UI says narration needs Piper).
List<AudioExportChapter> mp3ExportChapters(
  Iterable<AudioExportChapter> chapters,
) => [
  for (final chapter in chapters)
    if (chapter.path.toLowerCase().endsWith('.mp3')) chapter,
];

/// Builds the request of `converter_export_mp3_json_v1`.
String audioExportRequest({
  required String destination,
  required AudioExportLayout layout,
  required String title,
  String? author,
  String? cover,
  required List<AudioExportChapter> chapters,
}) => jsonEncode({
  'destination': destination,
  'layout': layout == AudioExportLayout.single ? 'single' : 'perChapter',
  'title': title,
  'author': ?author,
  'cover': ?cover,
  'chapters': [
    for (final chapter in chapters)
      {'title': chapter.title, 'path': chapter.path},
  ],
});

typedef AudioExportCall = Future<String?> Function(String requestJson);

Future<String?> _androidExport(String request) =>
    const MethodChannel('epub_to_mp3/embedded_converter')
        .invokeMethod<String>('exportMp3', {'request': request});

/// Exports finished chapter audio through Rust: one file or one per chapter, named "NN - title".
class AudioExporter {
  AudioExporter({AudioExportCall? call})
    : _call =
          call ?? (Platform.isAndroid ? _androidExport : desktopExportMp3Json);

  final AudioExportCall _call;

  Future<List<String>> export({
    required String destination,
    required AudioExportLayout layout,
    required String title,
    String? author,
    required List<AudioExportChapter> chapters,
  }) async {
    final raw = await _call(
      audioExportRequest(
        destination: destination,
        layout: layout,
        title: title,
        author: author,
        chapters: chapters,
      ),
    );
    if (raw == null) throw const AudioExportException('The export failed.');
    final files = (jsonDecode(raw) as Map)['files'] as List;
    return [for (final file in files) '$file'];
  }
}
