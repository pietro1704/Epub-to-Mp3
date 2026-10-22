import 'package:flutter_app/services/audiobook_downloads.dart';
import 'package:flutter_app/services/download_manager.dart' as legacy;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy download entrypoint retains the same download owner and event type', () async {
    final downloads = legacy.DownloadManager();
    final events = <legacy.DownloadEvent>[];
    final subscription = downloads.events.listen(events.add);
    try {
      expect(downloads, isA<AudiobookDownloads>());
      const completed = legacy.DownloadEvent(
        path: '/downloads/job/chapter.mp3',
        progress: 1,
        completed: true,
      );
      expect(completed, isA<DownloadEvent>());
      expect(completed.completed, isTrue);
      expect(events, isEmpty);
    } finally {
      downloads.dispose();
      await subscription.cancel();
    }
  });
}
