import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/storage/local_fulltext_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _book({List<Map<String, Object?>>? notes}) => {
  'jobId': 'book',
  'chapters': [
    {
      'index': 0,
      'name': 'One',
      'text': 'Body.',
      'footnotes': ?notes,
    },
  ],
};

void main() {
  test('chapters decode footnotes from the Rust metadata and round-trip them', () {
    final book = EbookFulltext.fromJson(
      _book(
        notes: [
          {'number': '1', 'text': 'First.'},
          {'text': 'Unlabelled.'},
        ],
      ),
    );
    final chapter = book.chapters.single;
    expect(chapter.hasFootnotes, isTrue);
    expect(chapter.footnotes!.map((note) => note.number), ['1', null]);
    final again = EbookFulltext.fromJson(
      jsonDecode(jsonEncode(book.toJson())) as Map<String, dynamic>,
    );
    expect(again.chapters.single.footnotes!.last.text, 'Unlabelled.');
  });

  test('chapters without the key or with an empty list have no footnotes', () {
    expect(EbookFulltext.fromJson(_book()).chapters.single.hasFootnotes, isFalse);
    expect(
      EbookFulltext.fromJson(_book(notes: const [])).chapters.single.hasFootnotes,
      isFalse,
    );
  });

  test('cache keeps footnotes and rebuilds entries from before they existed', () async {
    final directory = await Directory.systemTemp.createTemp('fulltext-notes-');
    addTearDown(() => directory.delete(recursive: true));
    final cache = LocalFulltextCache(directoryProvider: () async => directory);
    await cache.save(
      EbookFulltext.fromJson(_book(notes: [{'number': '1', 'text': 'Kept.'}])),
      'book1',
    );
    final cached = await cache.read('book1');
    expect(cached?.chapters.single.footnotes?.single.text, 'Kept.');

    final stale = File('${directory.path}/book1.json');
    final old = jsonDecode(await stale.readAsString()) as Map<String, dynamic>
      ..['readerContentVersion'] = 1;
    await stale.writeAsString(jsonEncode(old));
    expect(await cache.read('book1'), isNull, reason: 'older entries are re-parsed');
  });
}
