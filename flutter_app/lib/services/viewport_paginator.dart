import 'package:flutter/painting.dart';
import '../models/ebook_fulltext.dart';
import 'paginator.dart';

/// Splits rendered text at complete lines while retaining raw source ranges.
/// The renderer uses the same style, scale, width and per-span padding.
class ViewportPaginator {
  static List<ReaderPage> paginate({
    required List<SentenceSpan> spans,
    required double width,
    required double height,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection direction,
    double firstPageHeaderHeight = 0,
  }) {
    if (spans.isEmpty) return const [];
    if (width <= 0 || height <= 0) return const [];
    final pages = <ReaderPage>[];
    var page = <SentenceSpan>[];
    var used = firstPageHeaderHeight;
    for (final span in spans) {
      var offset = 0;
      var sourceOffset = span.startChar;
      while (offset < span.text.length) {
        final remaining = span.text.substring(offset);
        final painter = TextPainter(
          text: TextSpan(text: remaining, style: style),
          textDirection: direction, textScaler: textScaler,
        )..layout(maxWidth: width);
        final available = height - used - 4; // Renderer: vertical padding 2.
        var lineHeight = 0.0;
        var end = 0;
        for (final line in painter.computeLineMetrics()) {
          if (lineHeight + line.height > available + 0.001) break;
          lineHeight += line.height;
          final position = painter.getPositionForOffset(Offset(
            direction == TextDirection.ltr ? 0 : width, line.baseline));
          end = painter.getLineBoundary(position).end;
        }
        if (painter.height <= available + 0.001) {
          end = remaining.length;
          lineHeight = painter.height;
        }
        painter.dispose();
        if (end == 0) {
          if (page.isEmpty && used == 0) {
            throw StateError('The reader viewport cannot fit one complete text line');
          }
          pages.add(ReaderPage(List.unmodifiable(page)));
          page = [];
          used = 0;
          continue;
        }
        end = end.clamp(0, remaining.length);
        final fragment = remaining.substring(0, end);
        final sourceEnd = offset + end == span.text.length
            ? span.endChar : sourceOffset + fragment.runes.length;
        page.add(SentenceSpan(id: span.id, text: fragment,
          startChar: sourceOffset, endChar: sourceEnd));
        sourceOffset = sourceEnd;
        used += lineHeight + 4;
        offset += end;
        if (offset < span.text.length) {
          pages.add(ReaderPage(List.unmodifiable(page)));
          page = [];
          used = 0;
        }
      }
    }
    if (page.isNotEmpty) pages.add(ReaderPage(List.unmodifiable(page)));
    return pages;
  }
}
