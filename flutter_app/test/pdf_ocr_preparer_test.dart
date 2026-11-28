import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/conversion/pdf_ocr_preparer.dart';

void main() {
  late Directory dir;
  late String pdf;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('pdf-ocr');
    pdf = '${dir.path}/scan.pdf';
    File(pdf).writeAsBytesSync([1]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads each image page once and stores its text', () async {
    final stored = <int, String?>{};
    final preparer = PdfOcrPreparer(
      listPages: (_) async => [2, 3],
      recognize: (_, page) async => 'texto $page',
      store: (_, page, text) async => stored[page] = text,
    );
    expect(await preparer.prepare(pdf), 2);
    expect(stored, {2: 'texto 2', 3: 'texto 3'});
  });

  test('skips pages already stored in the sidecar and non-PDF books', () async {
    File('$pdf.ocr.json').writeAsStringSync(
      jsonEncode({
        'pages': {'2': 'ja lida'},
      }),
    );
    final read = <int>[];
    final preparer = PdfOcrPreparer(
      listPages: (_) async => [2, 3],
      recognize: (_, page) async {
        read.add(page);
        return 'x';
      },
      store: (_, _, _) async {},
    );
    expect(await preparer.prepare(pdf), 1);
    expect(read, [3]);
    expect(await preparer.prepare('${dir.path}/book.epub'), 0);
  });

  test('a page that fails or reads blank is skipped, not fatal', () async {
    final preparer = PdfOcrPreparer(
      listPages: (_) async => [1, 2],
      recognize: (_, page) async =>
          page == 1 ? throw StateError('boom') : '   ',
      store: (_, _, _) async => fail('nothing to store'),
    );
    expect(await preparer.prepare(pdf), 0);
  });
}
