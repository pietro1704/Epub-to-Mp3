import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/desktop_embedded_converter.dart';

void main() {
  final libraryPath = Platform.environment['TTS_TEST_FFI_LIBRARY'];
  final sourcePath = Platform.environment['TTS_TEST_EPUB'];
  test('real Rust FFI owns listening timing, source eligibility and closed control behavior', () {
    final schedule = DesktopListeningSchedule(ffi.DynamicLibrary.open(libraryPath!), 3);
    try {
      expect(schedule.permits(3), isTrue);
      expect(schedule.permits(4), isFalse);
      schedule.observeGeneration(8, 480);
      schedule.feedback(chapterIndex: 3, remainingSeconds: 20, playbackRate: 1);
      expect(schedule.permits(4), isFalse);
      schedule.feedback(chapterIndex: 3, remainingSeconds: 20, playbackRate: 2);
      expect(schedule.permits(4), isTrue);
      schedule.moveTo(4);
      expect(schedule.permits(3), isFalse);
      expect(schedule.permits(4), isTrue);
      expect(schedule.permits(5), isFalse);
      expect(() => schedule.feedback(chapterIndex: 3, remainingSeconds: 0, playbackRate: 1), throwsStateError);
      schedule.close();
      expect(schedule.permits(4), isFalse);
      expect(() => schedule.moveTo(3), throwsStateError);
      schedule.close();
    } finally { schedule.close(); }
  }, skip: libraryPath == null ? 'Provide an explicitly built converter-ffi library' : false);

  test('real desktop Rust conversion publishes the selected Unicode source remainder', () async {
    final converter = DesktopEmbeddedConverter(libraryPath: libraryPath!);
    final source = sourcePath!;
    final book = await converter.parse(inputPath: source);
    expect(book.jobId, '');
    final identified = await converter.parse(inputPath: source, jobId: 'captured-source');
    expect(identified.jobId, 'captured-source');
    final index = book.chapters.indexWhere((chapter) => chapter.text.runes.length > 8);
    expect(index, greaterThanOrEqualTo(0));
    final output = await Directory.systemTemp.createTemp('desktop-positioned-ffi-');
    var deliveredChunks = 0;
    try {
      final result = await converter.convertPositionedChapter(inputPath: source,
        outputPath: '${output.path}/selected', chapterIndex: index, textOffset: 3,
        optionsJson: '{"language":"en-US","tts_preferences":{"primary":{"engine":"system","model_id":null,"voice":null},"secondary":null,"allow_online_fallback":false}}',
        onFirstAudio: (source) async { deliveredChunks = source.chunkCount; });
      expect(result.chapterIndex, index);
      expect(result.textOffset, 3);
      expect(deliveredChunks, greaterThan(0));
      expect(await File(result.path).length(), greaterThan(100));
      expect(result.usedSelections.single.engine, 'system');
    } finally { await output.delete(recursive: true); }
  }, skip: libraryPath == null || sourcePath == null ? 'Provide explicit local FFI and EPUB fixtures' : false);
}
