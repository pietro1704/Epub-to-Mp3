import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

typedef PdfOcrListPages = Future<List<int>> Function(String path);
typedef PdfOcrRecognize = Future<String?> Function(String path, int page);
typedef PdfOcrStore = Future<void> Function(String path, int page, String text);

/// Reads the image-only pages of a PDF with the platform OCR and hands the text to the Rust
/// core (a sidecar it reads on open). Pages already stored are not read again; a page that
/// fails or reads blank is skipped so the rest of the book still opens.
class PdfOcrPreparer {
  PdfOcrPreparer({
    required this.listPages,
    required this.recognize,
    required this.store,
  });

  factory PdfOcrPreparer.android(MethodChannel channel) => PdfOcrPreparer(
    listPages: (path) async {
      final raw = await channel.invokeMethod<String>('pdfImagePages', {
        'path': path,
      });
      final pages = (jsonDecode(raw ?? '{}') as Map)['pages'] as List? ?? [];
      return pages.cast<num>().map((page) => page.toInt()).toList();
    },
    recognize: (path, page) => channel.invokeMethod<String>('pdfOcrPage', {
      'path': path,
      'page': page,
    }),
    store: (path, page, text) async {
      await channel.invokeMethod<String>('pdfOcrPageSet', {
        'path': path,
        'page': '$page',
        'text': text,
      });
    },
  );

  final PdfOcrListPages listPages;
  final PdfOcrRecognize recognize;
  final PdfOcrStore store;

  /// Returns how many pages were newly read.
  Future<int> prepare(String path) async {
    if (!path.toLowerCase().endsWith('.pdf')) return 0;
    final done = _storedPages(path);
    var read = 0;
    final List<int> pages;
    try {
      pages = await listPages(path);
    } on Object {
      return 0; // the open itself reports an unreadable PDF
    }
    for (final page in pages) {
      if (done.contains(page)) continue;
      try {
        final text = (await recognize(path, page))?.trim() ?? '';
        if (text.isEmpty) continue;
        await store(path, page, text);
        read++;
      } on Exception {
        continue;
      } on Error {
        continue;
      }
    }
    return read;
  }

  Set<int> _storedPages(String path) {
    try {
      final map = jsonDecode(File('$path.ocr.json').readAsStringSync()) as Map;
      return (map['pages'] as Map).keys.map((k) => int.parse('$k')).toSet();
    } on Object {
      return {};
    }
  }
}
