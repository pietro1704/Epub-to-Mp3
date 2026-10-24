part of 'desktop_embedded_converter.dart';

extension _DesktopPositionedChapter on DesktopEmbeddedConverter {
  Future<ConvertedChapterAudio> _positionedChapter({required String inputPath,
    required String outputPath, required int chapterIndex, required int textOffset,
    String? optionsJson, Future<void> Function(GrowingChapterAudioSource)? onFirstAudio}) async {
    final source = onFirstAudio == null ? null : GrowingChapterAudioSource(outputPath);
    if (_streams.containsKey(outputPath)) throw StateError('This output already owns an active stream');
    if (source != null) _streams[outputPath] = source;
    var delivered = false;
    try {
      final raw = await _runConversion(inputPath, outputPath, chapterIndex, chapterIndex, optionsJson,
        textOffset: textOffset,
        onChunk: source == null ? null : (event) async {
          if (event['chapterIndex'] != chapterIndex) throw StateError('Rust published another source chapter');
          await source.append((event['chunkIndex'] as num).toInt(), event['path'] as String);
          if (!delivered && source.chunkCount > 0) { delivered = true; await onFirstAudio!(source); }
        });
      final result = ConvertedChapterAudio.fromNativeResult(raw, expectedChapterIndex: chapterIndex);
      if (result.textOffset != textOffset) throw StateError('Rust returned another source text range');
      if (source != null && !delivered) throw StateError('Rust returned no playable source chunks');
      source?.complete();
      return result;
    } catch (error) { source?.fail(error); rethrow; }
    finally { _streams.remove(outputPath); }
  }
}
