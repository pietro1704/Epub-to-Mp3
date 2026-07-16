import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android background conversion bridge is declared', () {
    final kotlin = File('android/app/src/main/kotlin/com/pietrocode/epubtomp3/flutter_app/BackgroundChapterWorker.kt').readAsStringSync();
    final activity = File('android/app/src/main/kotlin/com/pietrocode/epubtomp3/flutter_app/MainActivity.kt').readAsStringSync();
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('androidx.work:work-runtime-ktx'));
    expect(kotlin, contains('convert_chapter'));
    expect(activity, contains('enqueueChapter'));
    expect(activity, contains('enqueueUniqueWork'));
  });
}
