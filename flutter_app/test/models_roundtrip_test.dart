import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/models/session_record.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('JobSnapshot decodes camelCase wire format', () {
    final json = {
      'jobId': 'abc',
      'state': 'running',
      'bookTitle': 'Foundation',
      'progressPercent': 42.5,
      'chaptersTotal': 12,
      'chapterProgress': [
        {
          'index': 0,
          'name': 'Prologue',
          'status': 'completed',
          'downloadUrl': '/files/0.mp3',
          'progressRatio': 1.0,
        },
      ],
      'outputs': [
        {'name': 'book.zip', 'url': '/files/book.zip', 'sizeBytes': 1024},
      ],
    };
    final snap = JobSnapshot.fromJson(json);
    expect(snap.jobId, 'abc');
    expect(snap.bookTitle, 'Foundation');
    expect(snap.chapterProgress!.first.displayTitle, 'Prologue');
    expect(snap.outputs!.first.isZip, true);
    expect(snap.isTerminal, false);
    expect(snap.playableChapters.length, 1);
  });

  test('JobSnapshot.playableChapters falls back to outputs[]', () {
    final snap = JobSnapshot(
      jobId: 'x',
      state: 'finished',
      outputs: const [
        OutputAsset(name: '1.mp3', url: '/1.mp3'),
        OutputAsset(name: 'log.txt', url: '/l'),
      ],
    );
    expect(snap.playableChapters.length, 1);
    expect(snap.playableChapters.first.downloadUrl, '/1.mp3');
  });

  test('SessionRecord decodes snake_case', () {
    final r = SessionRecord.fromJson({
      'timestamp': '2026-05-06',
      'book_title': 'Foo',
      'engine': 'edge',
      'chapters_converted': 5,
      'duration_seconds': 12.5,
      'outcome': 'success',
    });
    expect(r.bookTitle, 'Foo');
    expect(r.chaptersConverted, 5);
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
