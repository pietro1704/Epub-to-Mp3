import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/features/reader/epub_reader_resources.dart';

void main() {
  test(
    'adds presentation resources without changing Rust source identity or text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'reader-resources-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final archive = Archive();
      void add(String name, List<int> bytes) =>
          archive.addFile(ArchiveFile(name, bytes.length, bytes));
      add(
        'OPS/chapter.xhtml',
        utf8.encode(
          '<html><head><link rel="stylesheet" href="style.css"/></head><body><p>Original <em>text</em>.</p><img src="images/cover.png"/></body></html>',
        ),
      );
      add('OPS/style.css', utf8.encode('p { font-style: italic; }'));
      add('OPS/images/cover.png', [1, 2, 3]);
      final path = '${directory.path}/book.epub';
      File(path).writeAsBytesSync(ZipEncoder().encode(archive));
      final chapter = <String, dynamic>{
        'index': 7,
        'sourcePath': 'OPS/chapter.xhtml',
        'text': 'Original text.',
      };
      final result = await EpubReaderResources.enrich({
        'title': 'Book',
        'chapters': [chapter],
      }, path);
      final enriched = (result['chapters'] as List).single as Map;
      expect(enriched['index'], 7);
      expect(enriched['text'], 'Original text.');
      expect(enriched['html'], contains('<em>text</em>'));
      expect(enriched['html'], contains('data:image/png;base64,AQID'));
      expect(enriched['css'], contains('font-style: italic'));
      expect(result['bookTitle'], 'Book');
    },
  );
}
