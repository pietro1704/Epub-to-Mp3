import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/conversion/windows_page_ocr.dart';

void main() {
  test(
    'reads a page through PowerShell and returns the trimmed text',
    () async {
      final calls = <List<String>>[];
      var script = '';
      final ocr = WindowsPageOcr(
        run: (exe, args) async {
          calls.add([exe, ...args]);
          script = File(args[args.indexOf('-File') + 1]).readAsStringSync();
          return ProcessResult(0, 0, ' Texto lido \r\n', '');
        },
      );
      expect(await ocr.recognize(r'C:\books\scan.pdf', 3), 'Texto lido');
      expect(calls.single.first, 'powershell');
      expect(calls.single, containsAll(['-NoProfile', '-NonInteractive']));
      expect(calls.single.last, '3');
      expect(calls.single[calls.single.length - 2], r'C:\books\scan.pdf');
      expect(script, contains('Windows.Media.Ocr'));
    },
  );

  test(
    'no OCR language installed or a failing script reads as no text',
    () async {
      final ocr = WindowsPageOcr(
        run: (exe, args) async => ProcessResult(0, 1, '', 'no engine'),
      );
      expect(await ocr.recognize(r'C:\books\scan.pdf', 1), isNull);
      expect(await ocr.isAvailable(), isFalse);
    },
  );

  test('a missing PowerShell is unavailable', () async {
    final ocr = WindowsPageOcr(
      run: (exe, args) async => throw const ProcessException('powershell', []),
    );
    expect(await ocr.isAvailable(), isFalse);
    expect(await ocr.recognize(r'C:\x.pdf', 1), isNull);
  });
}
