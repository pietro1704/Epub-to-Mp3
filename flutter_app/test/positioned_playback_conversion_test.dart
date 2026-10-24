import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/growing_chapter_audio_source.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/services/rust_playback_conversion.dart';

class PositionedProbe extends UnavailableEmbeddedConverter implements PositionedChapterConverter {
  int? requestedOffset;
  bool wrongIdentity = false;
  @override
  Future<ConvertedChapterAudio> convertPositionedChapter({required String inputPath,
    required String outputPath, required int chapterIndex, required int textOffset, String? optionsJson,
    Future<void> Function(GrowingChapterAudioSource)? onFirstAudio}) async {
    requestedOffset = textOffset;
    final file = File('$outputPath/chapter.mp3')..writeAsBytesSync([1, 2, 3]);
    return ConvertedChapterAudio(chapterIndex: chapterIndex, path: file.path,
      title: 'Selected words', textOffset: wrongIdentity ? 0 : textOffset);
  }
}
void main() {
  for (final wrong in [false, true]) {
    test('positioned conversion ${wrong ? "rejects mismatched" : "persists exact"} source offsets', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final root = await Directory.systemTemp.createTemp('positioned-listen-');
      final changes = StreamController<int>.broadcast();
      final converter = PositionedProbe()..wrongIdentity = wrong;
      final service = RustPlaybackConversionService(converter: converter,
        coordinator: ConversionJobCoordinator(LocalConversionJobStore(prefs)));
      var completions = 0;
      final result = service.convert(bookId: 'book', jobId: 'partial', inputPath: '/book.epub',
        outputDirectory: root.path, chapters: [FulltextChapter(index: 0, text: 'á🙂 Selected words.')],
        initialChapterIndex: 0, initialTextOffset: 3, playbackChapterChanges: changes.stream,
        isActive: () => true, onChapterCompleted: (_, _, _) async { completions++; });
      try {
        if (wrong) { await expectLater(result, throwsStateError); expect(completions, 0); }
        else {
          final job = await result;
          expect(job.chapters.single.textOffset, 3);
          expect(job.coversFullSource([0]), isFalse);
          expect(LocalConversionJob.fromJson(job.toJson()).chapters.single.textOffset, 3);
          expect(completions, 1);
        }
        expect(converter.requestedOffset, 3);
      } finally { await changes.close(); await root.delete(recursive: true); }
    });
  }
}
