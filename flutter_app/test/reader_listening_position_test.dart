import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/reader_listening_position.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';

void main() {
  test('source offsets count Unicode scalars without splitting UTF16 pairs', () {
    const text = 'á🙂 Selected words.';
    final position = ReaderListeningPosition.fromUtf16(2, text, 4);
    expect(position.chapterIndex, 2);
    expect(position.textOffset, 3);
    expect(text.runes.skip(position.textOffset).map(String.fromCharCode).join(), 'Selected words.');
    for (final offset in [-1, 2, text.length]) {
      expect(() => ReaderListeningPosition.fromUtf16(2, text, offset), throwsFormatException);
    }
  });
  test('display scalar map preserves emoji, CRLF hard wraps and repeated text', () {
    const source = 'á🙂 First sentence.\r\nRepeated words.\r\n\r\nRepeated words.';
    final spans = FulltextChapter(index: 0, text: source).splitSentences();
    expect(spans.length, 3);
    for (final span in spans.skip(1)) {
      final position = ReaderListeningPosition.fromDisplayScalar(0, source, span.startChar);
      expect(String.fromCharCodes(source.runes.skip(position.textOffset)).startsWith(span.text), isTrue);
    }
    final first = ReaderListeningPosition.fromDisplayScalar(0, source, spans[1].startChar);
    final second = ReaderListeningPosition.fromDisplayScalar(0, source, spans[2].startChar);
    expect(second.textOffset, greaterThan(first.textOffset));
  });

}
