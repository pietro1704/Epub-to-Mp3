import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/listening_schedule.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/services/rust_playback_conversion.dart';

class ScheduleProbe implements ListeningSchedule {
  int chapter = 0;
  bool prefetch = false;
  bool closed = false;
  final feedbackChapters = <int>[];
  @override
  void moveTo(int index) { chapter = index; prefetch = false; }
  @override
  bool permits(int index) => index == chapter || (prefetch && index == chapter + 1);
  @override
  void feedback({required int chapterIndex, required double remainingSeconds, required double playbackRate}) {
    feedbackChapters.add(chapterIndex);
    prefetch = true;
  }
  @override
  void observeGeneration(double seconds, int textCharacters) {}
  @override
  void close() { closed = true; }
}
class ScheduledConverter extends UnavailableEmbeddedConverter implements ListeningScheduleFactory {
  final schedule = ScheduleProbe();
  final requested = <int>[];
  @override
  ListeningSchedule createListeningSchedule(int initialChapterIndex) {
    schedule.moveTo(initialChapterIndex);
    return schedule;
  }
  @override
  Future<ConvertedChapterAudio> convertChapter({required String inputPath,
    required String outputPath, required int chapterIndex, String? optionsJson}) async {
    requested.add(chapterIndex);
    final file = File('$outputPath/chapter.mp3')..writeAsBytesSync([1, 2, 3]);
    return ConvertedChapterAudio(chapterIndex: chapterIndex, path: file.path, title: 'Chapter');
  }
}
class ReplacedConverter extends ScheduledConverter implements CancellableEmbeddedConverter {
  final started = Completer<void>();
  final retired = Completer<ConvertedChapterAudio>();
  int calls = 0;
  @override
  Future<ConvertedChapterAudio> convertChapter({required String inputPath,
    required String outputPath, required int chapterIndex, String? optionsJson}) {
    if (calls++ == 0) { started.complete(); return retired.future; }
    return super.convertChapter(inputPath: inputPath, outputPath: outputPath,
      chapterIndex: chapterIndex, optionsJson: optionsJson);
  }
  @override
  Future<void> cancelConversion({String? inputPath, String? outputPath}) async {}
}
class PromotedConverter extends ScheduledConverter {
  final started = Completer<void>();
  final release = Completer<void>();
  String? pendingPath;
  @override
  Future<ConvertedChapterAudio> convertChapter({required String inputPath,
    required String outputPath, required int chapterIndex, String? optionsJson}) async {
    if (chapterIndex == 1) {
      pendingPath = outputPath;
      started.complete();
      await release.future;
    }
    return super.convertChapter(inputPath: inputPath, outputPath: outputPath,
      chapterIndex: chapterIndex, optionsJson: optionsJson);
  }
}
void main() {
  test('Rust eligibility gates prefetch and closes its control on cancellation', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final root = await Directory.systemTemp.createTemp('rust-listening-');
    final changes = StreamController<int>.broadcast();
    final converter = ScheduledConverter();
    final service = RustPlaybackConversionService(converter: converter,
      coordinator: ConversionJobCoordinator(LocalConversionJobStore(prefs)));
    final first = Completer<void>();
    final next = Completer<void>();
    final result = service.convert(bookId: 'book', jobId: 'listen', inputPath: '/book.epub',
      outputDirectory: root.path, chapters: List.generate(3, (index) =>
        FulltextChapter(index: index, text: 'Chapter $index')),
      initialChapterIndex: 0, playbackChapterChanges: changes.stream, isActive: () => true,
      onChapterCompleted: (chapter, _, _) async {
        if (chapter.index == 0) first.complete();
        if (chapter.index == 1) next.complete();
      });
    try {
      await first.future;
      await Future<void>.delayed(Duration.zero);
      expect(converter.requested, [0]);
      service.playbackFeedback(chapterIndex: 2, remainingSeconds: 0, playbackRate: 2);
      expect(converter.schedule.feedbackChapters, isEmpty);
      service.playbackFeedback(chapterIndex: 0, remainingSeconds: 1, playbackRate: 2);
      await next.future;
      expect(converter.requested, [0, 1]);
      await service.cancel();
      await result;
      expect(converter.schedule.closed, isTrue);
      service.playbackFeedback(chapterIndex: 0, remainingSeconds: 0, playbackRate: 2);
      expect(converter.schedule.feedbackChapters, [0]);
    } finally {
      await changes.close();
      await root.delete(recursive: true);
    }
  });
  for (final lateFailure in [false, true]) {
    test('A-B-A rejects retired ${lateFailure ? "failure" : "success"} after returning to the same chapter', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final root = await Directory.systemTemp.createTemp('rust-listening-epoch-');
      final changes = StreamController<int>.broadcast();
      final converter = ReplacedConverter();
      final service = RustPlaybackConversionService(converter: converter,
        coordinator: ConversionJobCoordinator(LocalConversionJobStore(prefs)));
      var completions = 0;
      final result = service.convert(bookId: 'book', jobId: 'epoch', inputPath: '/book.epub',
        outputDirectory: root.path, chapters: [FulltextChapter(index: 0, text: 'Current text')],
        initialChapterIndex: 0, playbackChapterChanges: changes.stream, isActive: () => true,
        onChapterCompleted: (_, _, _) async { completions++; });
      try {
        await converter.started.future;
        changes.add(1);
        await Future<void>.delayed(Duration.zero);
        changes.add(0);
        await Future<void>.delayed(Duration.zero);
        if (lateFailure) {
          converter.retired.completeError(StateError('Retired native cancellation'));
        } else {
          final stale = File('${root.path}/retired.mp3')..writeAsBytesSync([9]);
          converter.retired.complete(ConvertedChapterAudio(chapterIndex: 0, path: stale.path, title: 'Retired'));
        }
        final job = await result;
        expect(converter.calls, 2);
        expect(completions, 1);
        expect(job.chapters.single.status, 'completed');
        expect(converter.schedule.closed, isTrue);
      } finally {
        await changes.close();
        await root.delete(recursive: true);
      }
    });
  }

  test('promoting prefetch to current chapter retains its in-flight result', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final root = await Directory.systemTemp.createTemp('promoted-prefetch-');
    final changes = StreamController<int>.broadcast();
    final converter = PromotedConverter();
    final service = RustPlaybackConversionService(converter: converter,
      coordinator: ConversionJobCoordinator(LocalConversionJobStore(prefs)));
    final first = Completer<void>();
    final result = service.convert(bookId: 'book', jobId: 'prefetch', inputPath: '/book.epub',
      outputDirectory: root.path, chapters: List.generate(2, (index) => FulltextChapter(index: index, text: 'Text $index')),
      initialChapterIndex: 0, playbackChapterChanges: changes.stream, isActive: () => true,
      onChapterCompleted: (chapter, _, _) async { if (chapter.index == 0) first.complete(); });
    try {
      await first.future;
      await Future<void>.delayed(Duration.zero);
      service.playbackFeedback(chapterIndex: 0, remainingSeconds: 1, playbackRate: 1);
      await converter.started.future;
      changes.add(1);
      await Future<void>.delayed(Duration.zero);
      converter.release.complete();
      final job = await result;
      expect(converter.requested, [0, 1]);
      expect(job.coversFullSource([0, 1]), isTrue);
      expect(await File('${converter.pendingPath}/chapter.mp3').exists(), isTrue);
    } finally { await changes.close(); await root.delete(recursive: true); }
  });

}
