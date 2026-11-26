import 'package:flutter_app/services/conversion/local_conversion_record.dart';
import 'package:flutter_app/views/reader_toc_audio_state.dart';
import 'package:flutter_test/flutter_test.dart';

LocalConversionJob _job(List<LocalConversionChapter> chapters) => LocalConversionJob(
  bookId: 'b',
  jobId: 'local-b',
  chapters: chapters,
  status: LocalConversionJobStatus.running,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  test('a chapter with finished audio is ready, a failed one is failed, one in progress is converting', () {
    final states = chapterAudioStates(_job(const [
      LocalConversionChapter(index: 0, name: 'One', status: 'completed', outputPath: '/a/1.mp3'),
      LocalConversionChapter(index: 1, name: 'Two', status: 'failed', error: 'boom'),
      LocalConversionChapter(index: 2, name: 'Three', status: 'running'),
      LocalConversionChapter(index: 3, name: 'Four', status: 'pending'),
    ]));
    expect(states, {
      0: ChapterAudioState.ready,
      1: ChapterAudioState.failed,
      2: ChapterAudioState.converting,
    });
  });

  test('a completed chapter without an output file is not ready and no job means no state', () {
    expect(
      chapterAudioStates(_job(const [LocalConversionChapter(index: 0, name: 'One', status: 'completed')])),
      isEmpty,
    );
    expect(chapterAudioStates(null), isEmpty);
  });
}
