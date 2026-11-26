import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/book_language_corrections.dart';

void main() {
  test('a passage scope uses the chapter position and source scalars, not the chapter identifier', () {
    // Rust routes overrides by the chapter's position in the book (cover and
    // front matter included), counting Unicode scalars of the chapter text.
    const text = 'a😀b. Second part here.';
    final scope = PassageLanguageCorrection.forSelection(
      text: text,
      range: const TextRange(start: 6, end: 12),
      chapterPosition: 2,
    );
    expect(scope!.chapterIndex, 2);
    expect(scope.start, 5);
    expect(scope.end, 11);
    expect(text.runes.skip(scope.start).take(scope.end - scope.start), 'Second'.runes);
  });

  test('an out-of-range selection yields no scope', () {
    expect(
      PassageLanguageCorrection.forSelection(
        text: 'abc',
        range: const TextRange(start: 1, end: 9),
        chapterPosition: 0,
      ),
      isNull,
    );
  });
}
