// Smoke + contract tests for the Chaquopy bridge (Android only).
//
// The real Python runtime only exists when the app is running on an
// Android device/emulator, so most of these are MethodChannel-mocked
// unit tests. The full end-to-end call lives behind a `runOnDevice`
// gate that is skipped in headless `flutter test`.

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/python_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('epub_to_mp3/python');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'bootstrap':
          return '3.13.0 (main, stub) [Chaquopy]';
        case 'parseEpub':
          final path = (call.arguments as Map?)?['path'] as String?;
          if (path == null || path.isEmpty) {
            throw PlatformException(code: 'BAD_ARGS', message: 'empty path');
          }
          return jsonEncode({
            'jobId': '',
            'bookTitle': 'Mock Book',
            'bookAuthor': 'Mock Author',
            'chapters': [
              {
                'index': 1,
                'name': 'Intro',
                'text': 'Hello world.',
                'charCount': 12,
                'level': 1,
              },
              {
                'index': 2,
                'name': 'Chapter 1',
                'text': 'Once upon a time.',
                'charCount': 17,
                'level': 1,
              },
            ],
          });
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('isSupported is true only on Android or Linux/Windows desktop', () {
    // We can't override Platform.* from tests cleanly, so just assert
    // the result is consistent with the current host.
    final expected = Platform.isAndroid ||
        Platform.isLinux ||
        Platform.isWindows;
    expect(PythonBridge.instance.isSupported, expected);
  });

  test('bootstrap returns Python version string', () async {
    final version = await PythonBridge.instance.bootstrap();
    expect(version, contains('3.13'));
  });

  test('parseEpub decodes JSON into EbookFulltext', () async {
    final book = await PythonBridge.instance
        .parseEpub('/fake/path.epub', jobId: 'job-42');
    expect(book, isA<EbookFulltext>());
    expect(book.jobId, 'job-42');
    expect(book.bookTitle, 'Mock Book');
    expect(book.chapters.length, 2);
    expect(book.chapters.first.text, 'Hello world.');
    expect(book.chapters.first.charCount, 12);
  });

  test('parseEpub surfaces PlatformException on empty path', () async {
    expect(
      () => PythonBridge.instance.parseEpub(''),
      throwsA(isA<PlatformException>()),
    );
  });
}
