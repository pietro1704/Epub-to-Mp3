import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/viewport_paginator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('retains actual splitSentences boundaries including trimmed source whitespace', () {
    const chapter = FulltextChapter(index: 0, text: '  Hello.  Ação 👋  ');
    final spans = chapter.splitSentences();
    final pages = ViewportPaginator.paginate(spans: spans, width: 400, height: 600,
      style: const TextStyle(fontSize: 20), textScaler: TextScaler.noScaling, direction: TextDirection.ltr);
    expect(pages.single.spans, spans);
  });
  test('long paragraphs preserve every raw character and fit complete rendered pages', () {
    final text = 'Ação e coração 👨‍👩‍👧‍👦. ' * 180;
    final spans = [SentenceSpan(id: 'source', text: text, startChar: 17, endChar: 17 + text.runes.length)];
    for (final scale in [1.0, 1.6]) {
      const style = TextStyle(fontSize: 24, height: 1.5, fontFamily: 'serif');
      final scaler = TextScaler.linear(scale);
      final pages = ViewportPaginator.paginate(spans: spans, width: 260, height: 480,
        style: style, textScaler: scaler, direction: TextDirection.ltr, firstPageHeaderHeight: 90);
      expect(pages.length, greaterThan(1));
      expect(pages.expand((p) => p.spans).map((s) => s.text).join(), text);
      var offset = 17;
      for (var index = 0; index < pages.length; index++) {
        var height = index == 0 ? 90.0 : 0.0;
        for (final span in pages[index].spans) {
          expect(span.startChar, offset);
          offset = span.endChar;
          final painter = TextPainter(text: TextSpan(text: span.text, style: style),
            textDirection: TextDirection.ltr, textScaler: scaler)..layout(maxWidth: 260);
          height += painter.height + 4;
          painter.dispose();
        }
        expect(height, lessThanOrEqualTo(480.001));
      }
      expect(offset, 17 + text.runes.length);
    }
  });

  test('empty text, impossible viewport and multiple spans are explicit', () {
    const style = TextStyle(fontSize: 24);
    List<SentenceSpan> spans = [const SentenceSpan(id: 'one', text: 'First.', startChar: 0, endChar: 6),
      const SentenceSpan(id: 'two', text: 'Second.', startChar: 8, endChar: 15)];
    final pages = ViewportPaginator.paginate(spans: spans, width: 300, height: 400,
      style: style, textScaler: TextScaler.noScaling, direction: TextDirection.ltr);
    expect(pages.single.spans, spans);
    expect(ViewportPaginator.paginate(spans: [], width: 300, height: 400,
      style: style, textScaler: TextScaler.noScaling, direction: TextDirection.ltr), isEmpty);
    expect(() => ViewportPaginator.paginate(spans: spans, width: 300, height: 1,
      style: style, textScaler: TextScaler.noScaling, direction: TextDirection.ltr), throwsStateError);
  });
}
