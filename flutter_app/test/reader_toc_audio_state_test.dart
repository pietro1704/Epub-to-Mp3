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

  group('contents download actions', () {
    const r = ChapterAudioState.ready, c = ChapterAudioState.converting, f = ChapterAudioState.failed;

    test('nothing downloaded offers only Download', () {
      expect(contentsDownloadActions(const {}, 3), [ContentsDownloadAction.downloadAll]);
    });

    test('converting offers Cancel and Download stays hidden while it runs', () {
      expect(contentsDownloadActions({0: r, 1: c}, 3), [ContentsDownloadAction.cancel]);
    });

    test('failed chapters add Retry and the first failed chapter is known', () {
      expect(contentsDownloadActions({0: r, 1: f}, 3), [
        ContentsDownloadAction.downloadAll,
        ContentsDownloadAction.retryFailed,
      ]);
      expect(firstFailedChapter({0: r, 2: f, 1: f}), 1);
      expect(firstFailedChapter({0: r}), isNull);
    });

    test('a fully ready book offers no download', () {
      expect(contentsDownloadActions({0: r, 1: r}, 2), isEmpty);
    });
  });
}
