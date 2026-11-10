import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/rendering.dart';

/// Geometry measured from the actual rich text, including inline resources.
/// Source positions are UTF-16 offsets into the unmodified chapter text.
class ReaderDocumentGeometry {
  ReaderDocumentGeometry(this.height, this.fragments, this.paragraphs);

  final double height;
  final List<Rect> fragments;
  final List<MappedReaderParagraph> paragraphs;

  static ReaderDocumentGeometry measure(RenderBox content, String source) {
    final fragments = <Rect>[];
    final paragraphs = <MappedReaderParagraph>[];
    final normalized = NormalizedReaderText(source);
    var cursor = 0;
    void visit(RenderObject object) {
      if (object is RenderParagraph && object.hasSize) {
        final text = object.text.toPlainText(includeSemanticsLabels: false);
        final origin = object.localToGlobal(Offset.zero, ancestor: content);
        var textOffset = 0;
        void protect(InlineSpan span) {
          if (span is TextSpan) {
            final length = span.text?.length ?? 0;
            if (length > 0) {
              fragments.addAll(
                object
                    .getBoxesForSelection(
                      TextSelection(
                        baseOffset: textOffset,
                        extentOffset: textOffset + length,
                      ),
                      boxHeightStyle: BoxHeightStyle.max,
                    )
                    .map((box) => box.toRect().shift(origin)),
              );
            }
            textOffset += length;
            for (final child in span.children ?? const <InlineSpan>[]) {
              protect(child);
            }
          } else if (span is PlaceholderSpan) {
            textOffset++;
          }
        }

        protect(object.text);
        final rendered = NormalizedReaderText(text);
        final match = rendered.text.isEmpty || text.contains('\uFFFC')
            ? -1
            : normalized.text.indexOf(rendered.text, cursor);
        if (match >= 0) {
          paragraphs.add(
            MappedReaderParagraph(object, origin, rendered, normalized, match),
          );
          cursor = match + rendered.text.length;
        }
      } else if (object is RenderImage && object.hasSize) {
        fragments.add(
          object.localToGlobal(Offset.zero, ancestor: content) & object.size,
        );
      }
      object.visitChildren(visit);
    }

    visit(content);
    fragments.sort((a, b) => a.top.compareTo(b.top));
    return ReaderDocumentGeometry(content.size.height, fragments, paragraphs);
  }

  /// Boundaries are only used by explicit page turns, never a chrome toggle.
  List<double> pageOffsets(double viewport) {
    if (viewport <= 0) return const [0];
    final offsets = <double>[0];
    while (offsets.last + viewport < height - 0.5) {
      final start = offsets.last;
      var end = start + viewport;
      for (final fragment in fragments) {
        if (fragment.top < end - 0.5 && fragment.bottom > end + 0.5) {
          if (fragment.height > viewport) return const [];
          end = fragment.top;
        }
      }
      if (end <= start + 0.5) return const [];
      offsets.add(end);
    }
    return offsets;
  }

  int? sourceOffsetAt(double top) {
    for (final paragraph in paragraphs) {
      if (!paragraph.render.attached || !paragraph.render.hasSize) continue;
      if (paragraph.origin.dy + paragraph.render.size.height <= top) continue;
      return paragraph.sourceOffsetAt(
        Offset(
          0,
          (top - paragraph.origin.dy).clamp(0, paragraph.render.size.height),
        ),
      );
    }
    return null;
  }

  List<Rect> boxesFor(TextRange sourceRange) => [
    for (final paragraph in paragraphs) ...paragraph.boxesFor(sourceRange),
  ];

  /// Cover only the fragments intersecting viewport edges, not whole lines.
  (double, double) edgeGuards(double offset, double viewport) {
    var top = 0.0;
    var bottom = 0.0;
    for (final fragment in fragments) {
      if (fragment.height > viewport) continue;
      if (fragment.top < offset - 0.5 && fragment.bottom > offset + 0.5) {
        top = (fragment.bottom - offset).clamp(top, viewport);
      }
      if (fragment.top < offset + viewport - 0.5 &&
          fragment.bottom > offset + viewport + 0.5) {
        bottom = (offset + viewport - fragment.top).clamp(bottom, viewport);
      }
    }
    return (top, bottom);
  }
}

/// Whitespace normalization retains a reversible mapping to source UTF-16.
class NormalizedReaderText {
  NormalizedReaderText(String source) {
    final output = StringBuffer();
    var whitespace = false;
    for (var i = 0; i < source.length; i++) {
      final character = source[i];
      if (RegExp(r'\s').hasMatch(character)) {
        if (output.isNotEmpty && !whitespace) {
          output.write(' ');
          offsets.add(i);
          whitespace = true;
        }
      } else {
        output.write(character);
        offsets.add(i);
        whitespace = false;
      }
    }
    text = output.toString().trimRight();
    if (offsets.length > text.length) offsets.removeLast();
    offsets.add(source.length);
  }
  late final String text;
  final List<int> offsets = [];
}

class MappedReaderParagraph {
  MappedReaderParagraph(
    this.render,
    this.origin,
    this.rendered,
    this.source,
    this.start,
  );
  final RenderParagraph render;
  final Offset origin;
  final NormalizedReaderText rendered;
  final NormalizedReaderText source;
  final int start;

  int sourceOffsetAt(Offset position) {
    final local = render.getPositionForOffset(position).offset;
    var normalized = rendered.offsets.indexWhere((offset) => offset >= local);
    if (normalized < 0) normalized = rendered.text.length;
    return source.offsets[(start + normalized).clamp(0, source.text.length)];
  }

  List<Rect> boxesFor(TextRange range) {
    if (!render.attached || !render.hasSize) return const [];
    final first = source.offsets.indexWhere((offset) => offset >= range.start);
    final last = source.offsets.indexWhere((offset) => offset >= range.end);
    if (first < 0 ||
        last < 0 ||
        last <= start ||
        first >= start + rendered.text.length) {
      return const [];
    }
    final localStart =
        rendered.offsets[(first - start).clamp(0, rendered.text.length)];
    final localEnd =
        rendered.offsets[(last - start).clamp(0, rendered.text.length)];
    return render
        .getBoxesForSelection(
          TextSelection(baseOffset: localStart, extentOffset: localEnd),
        )
        .map((box) => box.toRect().shift(origin))
        .toList();
  }
}
