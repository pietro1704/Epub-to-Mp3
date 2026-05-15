import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/paginator.dart';

SentenceSpan _span(String text, {String? id}) =>
    SentenceSpan(id: id ?? '0:0', text: text, startChar: 0, endChar: text.length);

void main() {
  group('Paginator', () {
    test('empty input returns no pages', () {
      final pages = Paginator.paginate(spans: []);
      expect(pages, isEmpty);
    });

    test('single short span fits one page', () {
      final pages = Paginator.paginate(spans: [_span('Hello')]);
      expect(pages.length, 1);
      expect(pages.first.spans.length, 1);
    });

    test('splits at page boundary', () {
      final span = _span('x' * 800);
      final pages = Paginator.paginate(
        spans: [span, span, span],
        pageSize: 1500,
      );
      expect(pages.length, greaterThan(1));
      expect(pages.length, 3);
    });

    test('large single span gets its own page', () {
      final big = _span('x' * 3000);
      final small = _span('y' * 10);
      final pages = Paginator.paginate(
        spans: [big, small],
        pageSize: 1500,
      );
      expect(pages.length, 2);
      expect(pages[0].spans.first.text.length, 3000);
      expect(pages[1].spans.first.text.length, 10);
    });

    test('last page can be short', () {
      final spans = List.generate(5, (i) => _span('word ' * 50, id: '0:$i'));
      final pages = Paginator.paginate(spans: spans, pageSize: 500);
      expect(pages.isNotEmpty, isTrue);
      final lastLen =
          pages.last.spans.fold<int>(0, (a, s) => a + s.text.length);
      expect(lastLen <= 500, isTrue);
    });
  });
}
