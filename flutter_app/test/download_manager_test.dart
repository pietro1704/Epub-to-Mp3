import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/download_manager.dart';

void main() {
  group('DownloadEvent', () {
    test('completed event has no error', () {
      const ev = DownloadEvent(path: '/a.mp3', progress: 1.0, completed: true);
      expect(ev.completed, isTrue);
      expect(ev.error, isNull);
    });

    test('error event carries message', () {
      const ev =
          DownloadEvent(path: '/a.mp3', progress: 0, error: 'timeout');
      expect(ev.completed, isFalse);
      expect(ev.error, 'timeout');
    });

    test('progress event mid-download', () {
      const ev = DownloadEvent(path: '/a.mp3', progress: 0.5);
      expect(ev.completed, isFalse);
      expect(ev.error, isNull);
      expect(ev.progress, 0.5);
    });
  });

  group('DownloadManager', () {
    test('events stream is broadcast', () {
      final dm = DownloadManager();
      final s1 = dm.events.listen((_) {});
      final s2 = dm.events.listen((_) {});
      s1.cancel();
      s2.cancel();
      dm.dispose();
    });
  });
}
