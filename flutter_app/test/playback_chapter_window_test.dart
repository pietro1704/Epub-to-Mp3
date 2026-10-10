import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/playback_chapter_window.dart';

void main() {
  test('keeps only the current chapter and one chapter ahead eligible', () {
    const window = PlaybackChapterWindow();

    expect(window.contains(4, 3), isFalse);
    expect(window.contains(4, 4), isTrue);
    expect(window.contains(4, 5), isTrue);
    expect(window.contains(4, 6), isFalse);
  });
}
