import 'dart:convert';

import '../models/tts_preferences.dart';
import 'embedded_conversion_contract.dart';

class ConvertedChapterAudio {
  const ConvertedChapterAudio({
    required this.chapterIndex,
    required this.path,
    required this.title,
    this.usedSelections = const [],
    this.fallbackUsed = false,
    this.ttsPolicyState,
  });

  final List<TtsSelection> usedSelections;
  final bool fallbackUsed;
  final Map<String, dynamic>? ttsPolicyState;
  final int chapterIndex;
  final String path;
  final String title;

  static ConvertedChapterAudio fromNativeResult(
    String raw, {
    required int expectedChapterIndex,
  }) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded['audioPath'] is! String) {
      throw EmbeddedConversionFailure(
        'INVALID_CHAPTER_RESULT',
        'Rust converter returned no chapter audio path',
      );
    }
    final manifest = decoded['manifest'];
    final entries = manifest is Map ? manifest['chapters'] : null;
    if (entries is! List || entries.length != 1 || entries.single is! Map) {
      throw EmbeddedConversionFailure(
        'INVALID_CHAPTER_RESULT',
        'Rust converter did not return exactly one requested chapter',
      );
    }
    final entry = Map<String, dynamic>.from(entries.single as Map);
    final sourceIndex = entry['sourceIndex'];
    if (sourceIndex is! num || sourceIndex.toInt() != expectedChapterIndex) {
      throw EmbeddedConversionFailure(
        'CHAPTER_INDEX_MISMATCH',
        'Rust returned an unexpected source chapter for request $expectedChapterIndex',
      );
    }
    return ConvertedChapterAudio(
      chapterIndex: expectedChapterIndex,
      path: decoded['audioPath'] as String,
      title: entry['title'] as String? ?? '',
      fallbackUsed: manifest['fallbackUsed'] == true,
      usedSelections: (manifest['usedSelections'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (selection) =>
                TtsSelection.fromJson(Map<String, dynamic>.from(selection)),
          )
          .toList(growable: false),
      ttsPolicyState: manifest['ttsPolicyState'] is Map
          ? Map<String, dynamic>.from(manifest['ttsPolicyState'] as Map)
          : null,
    );
  }
}
