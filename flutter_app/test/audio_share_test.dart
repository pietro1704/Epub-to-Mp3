import 'dart:io';

import 'package:flutter_app/services/audio_share.dart';
import 'package:flutter_app/services/conversion/local_conversion_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only finished chapters whose file still exists are shared, in chapter order', () {
    final dir = Directory.systemTemp.createTempSync('share');
    addTearDown(() => dir.deleteSync(recursive: true));
    final two = File('${dir.path}/2.mp3')..writeAsStringSync('x');
    final zero = File('${dir.path}/0.mp3')..writeAsStringSync('x');
    final job = LocalConversionJob(
      bookId: 'b',
      jobId: 'local-b',
      status: LocalConversionJobStatus.running,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      chapters: [
        LocalConversionChapter(index: 2, name: 'c2', status: 'completed', outputPath: two.path),
        LocalConversionChapter(index: 1, name: 'c1', status: 'failed'),
        LocalConversionChapter(index: 0, name: 'c0', status: 'completed', outputPath: zero.path),
        const LocalConversionChapter(index: 3, name: 'c3', status: 'completed', outputPath: '/gone.mp3'),
      ],
    );
    expect(availableAudioPaths(job), [zero.path, two.path]);
    expect(availableAudioPaths(null), isEmpty);
  });
}
