import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';

import '../../models/ebook_fulltext.dart';

class ReaderPage {
  final List<SentenceSpan> spans;
  const ReaderPage(this.spans);
}

/// Splits rendered text at complete lines while retaining raw source ranges.
/// The renderer uses the same style, scale, width and per-span padding.
class ViewportPaginator {
  /// Characters sent to text layout, so a test can prove a long span is not laid out
  /// again in full for every page.
  @visibleForTesting
  static int laidOutChars = 0;

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
    if (firstPageHeaderHeight > height) {
      throw StateError('The reader viewport cannot fit its chapter header');
    }
    final pages = <ReaderPage>[];
    var page = <SentenceSpan>[];
    var used = firstPageHeaderHeight;
    for (final span in spans) {
      var offset = 0;
      var sourceOffset = span.startChar;
      while (offset < span.text.length) {
        // Only the text that can reach this page is laid out. The last line of a
        // window may be cut short, so it is never used; if every other line fits,
        // the window doubles. Lines before it break exactly as in the full remainder.
        final all = span.text.substring(offset);
        var window = 3000;
        late String remaining;
        var end = 0;
        var lineHeight = 0.0;
        while (true) {
          final complete = all.length <= window;
          remaining = complete ? all : all.substring(0, window);
          final painter = TextPainter(
            text: TextSpan(text: remaining, style: style),
            textDirection: direction,
            textScaler: textScaler,
          )..layout(maxWidth: width);
          laidOutChars += remaining.length;
          final available = height - used - 4; // Renderer: vertical padding 2.
          lineHeight = 0.0;
          end = 0;
          final metrics = painter.computeLineMetrics();
          final usable = complete ? metrics : metrics.take(metrics.length - 1);
          var stopped = false;
          for (final line in usable) {
            if (lineHeight + line.height > available + 0.001) {
              stopped = true;
              break;
            }
            lineHeight += line.height;
            final position = painter.getPositionForOffset(
              Offset(direction == TextDirection.ltr ? 0 : width, line.baseline),
            );
            end = painter.getLineBoundary(position).end;
          }
          if (complete && painter.height <= available + 0.001) {
            end = remaining.length;
            lineHeight = painter.height;
          }
          painter.dispose();
          if (complete || stopped) break;
          window *= 2;
        }
        if (end == 0) {
          if (page.isEmpty && used == 0) {
            throw StateError(
              'The reader viewport cannot fit one complete text line',
            );
          }
          pages.add(ReaderPage(List.unmodifiable(page)));
          page = [];
          used = 0;
          continue;
        }
        end = end.clamp(0, remaining.length);
        final fragment = remaining.substring(0, end);
        final sourceEnd = offset + end == span.text.length
            ? span.endChar
            : sourceOffset + fragment.runes.length;
        page.add(
          SentenceSpan(
            id: span.id,
            text: fragment,
            startChar: sourceOffset,
            endChar: sourceEnd,
          ),
        );
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
