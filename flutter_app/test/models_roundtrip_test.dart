import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ChapterProgress decodes camelCase wire format', () {
    final chapter = ChapterProgress.fromJson({
      'index': 0,
      'name': 'Prologue',
      'status': 'completed',
      'downloadUrl': 'file:///audio/0.mp3',
      'progressRatio': 1.0,
      'futureRustField': true,
    });
    expect(chapter.displayTitle, 'Prologue');
    expect(chapter.isCompleted, true);
  });

  test('FulltextChapter splits sentences', () {
    final c = FulltextChapter(
      index: 1,
      text: 'Hello world. This is two! And three?',
    );
    final spans = c.splitSentences();
    expect(spans.length, 3);
    expect(spans.first.id, '1:0');
    expect(spans.first.text, 'Hello world.');
  });

  test('collapseHardWraps joins single newlines, preserves double', () {
    const input = 'Hello\nworld.\n\nNew paragraph.';
    final result = FulltextChapter.collapseHardWraps(input);
    expect(result, 'Hello world.\n\nNew paragraph.');
  });

  test('splitSentences does not break on newline mid-word', () {
    final c = FulltextChapter(
      index: 0,
      text: 'The quick brown\nfox jumps. Over the lazy dog!',
    );
    final spans = c.splitSentences();
    expect(spans.length, 2);
    expect(spans.first.text, 'The quick brown fox jumps.');
    expect(spans.last.text, 'Over the lazy dog!');
  });

  test('EbookFulltext decodes', () {
    final ft = EbookFulltext.fromJson({
      'jobId': 'z',
      'bookTitle': 'Z',
      'chapters': [
        {'index': 0, 'name': 'Ch1', 'text': 'Hi.'},
      ],
    });
    expect(ft.chapters.first.name, 'Ch1');
  });
}
