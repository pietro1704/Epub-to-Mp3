import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/conversion/linux_page_ocr.dart';

void main() {
  test(
    'renders the page with pdftoppm and reads it with the installed languages',
    () async {
      final calls = <List<String>>[];
      final ocr = LinuxPageOcr(
        run: (exe, args) async {
          calls.add([exe, ...args]);
          if (exe == 'tesseract' && args.contains('--list-langs')) {
            return ProcessResult(
              0,
              0,
              'List of available languages (3):\nosd\npor\neng\n',
              '',
            );
          }
          if (exe == 'pdftoppm') {
            File('${args.last}.png').writeAsBytesSync([1]);
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 0, ' Texto lido \n', '');
        },
      );
      expect(await ocr.recognize('/books/scan.pdf', 3), 'Texto lido');
      final render = calls.firstWhere((c) => c.first == 'pdftoppm');
      expect(
        render,
        containsAllInOrder(['-f', '3', '-l', '3', '-png', '-singlefile']),
      );
      final read = calls.lastWhere((c) => c.first == 'tesseract');
      expect(read, containsAllInOrder(['stdout', '-l', 'por+eng']));
    },
  );

  test('is unavailable when tesseract or pdftoppm is not installed', () async {
    final ocr = LinuxPageOcr(
      run: (exe, args) async => throw const ProcessException('x', []),
    );
    expect(await ocr.isAvailable(), isFalse);
    expect(await ocr.recognize('/books/scan.pdf', 1), isNull);
  });

  test('a failing tesseract reads as no text', () async {
    final ocr = LinuxPageOcr(
      run: (exe, args) async =>
          exe == 'tesseract' && !args.contains('--list-langs')
          ? ProcessResult(0, 1, '', 'boom')
          : ProcessResult(0, 0, 'List\nosd\neng\n', ''),
    );
    expect(await ocr.recognize('/books/scan.pdf', 1), isNull);
  });
}
