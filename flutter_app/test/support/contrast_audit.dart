// WCAG 2.2 AA contrast audit for widget tests (card CONTRAST-AUDIT). Every visible text and icon
// is measured against the ACTUAL pixels around it (a ring just outside its box in a rendered
// frame), so gradients, cards, dialogs and tints are measured as the user sees them, and the
// foreground is the resolved colour of its text style (alpha composited). Limits: text 4.5:1,
// large text (>= 18 pt, or >= 14 pt bold) 3:1, icons / UI glyphs 3:1.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

double relativeLuminance(Color c) => c.computeLuminance();

double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a), lb = relativeLuminance(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

class ContrastFinding {
  ContrastFinding({
    required this.kind,
    required this.label,
    required this.ratio,
    required this.required,
    required this.foreground,
    required this.background,
    required this.rect,
  });
  final String kind; // text | icon
  final String label;
  final double ratio, required;
  final Color foreground, background;
  final Rect rect;

  String _hex(Color c) =>
      '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

  @override
  String toString() =>
      '$kind "$label" ${ratio.toStringAsFixed(2)}:1 (needs ${required.toStringAsFixed(1)}:1) '
      'fg ${_hex(foreground)} on ${_hex(background)} at ${rect.left.round()},${rect.top.round()} '
      '${rect.width.round()}x${rect.height.round()}';
}

/// Wrap the app (or the screen under test) in this, with [boundaryKey], before pumping it.
class AuditHost extends StatelessWidget {
  const AuditHost({super.key, required this.boundaryKey, required this.child});
  final GlobalKey boundaryKey;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: boundaryKey, child: child);
}

Future<List<ContrastFinding>> auditContrast(
  WidgetTester tester,
  GlobalKey boundaryKey,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1));
  final data = (await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
  ))!;
  final width = image!.width, height = image.height;
  Color pixel(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }

  // The most frequent colour of a ring of pixels just outside [rect]: the background of the text.
  Color? background(Rect rect) {
    final counts = <int, int>{};
    void add(int x, int y) {
      if (x < 0 || y < 0 || x >= width || y >= height) return;
      final c = pixel(x, y);
      counts.update(c.toARGB32() & 0xfffffff8, (n) => n + 1, ifAbsent: () => 1);
    }

    final left = rect.left.floor() - 3, right = rect.right.ceil() + 2;
    final top = rect.top.floor() - 3, bottom = rect.bottom.ceil() + 2;
    for (var x = left; x <= right; x++) {
      add(x, top);
      add(x, bottom);
    }
    for (var y = top; y <= bottom; y++) {
      add(left, y);
      add(right, y);
    }
    if (counts.isEmpty) return null;
    final best = counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    return Color(0xff000000 | best);
  }

  final findings = <ContrastFinding>[];
  final seen = <String>{};
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject;
    if (paragraph is! RenderParagraph ||
        !paragraph.hasSize ||
        !paragraph.attached) {
      continue;
    }
    final span = paragraph.text;
    final style = span is TextSpan ? span.style : null;
    final text = span.toPlainText().trim();
    if (text.isEmpty || style?.color == null) continue;
    final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
    if (rect.width < 1 ||
        rect.height < 1 ||
        rect.right < 0 ||
        rect.bottom < 0 ||
        rect.left >= width ||
        rect.top >= height) {
      continue;
    }
    // A text clipped away by a scrollable or an offscreen route is not on screen.
    final inView = rect.overlaps(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    );
    if (!inView) continue;
    // WCAG exempts inactive components: text inside a disabled button / list tile is not audited.
    var disabled = false;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if ((widget is ButtonStyleButton && !widget.enabled) ||
          (widget is ListTile && !widget.enabled)) {
        disabled = true;
        return false;
      }
      return true;
    });
    if (disabled) {
      continue;
    }
    final isIcon =
        style!.fontFamily == 'MaterialIcons' ||
        (style.fontFamily?.contains('Icons') ?? false);
    final fontSize = style.fontSize ?? 14;
    final bold = (style.fontWeight?.value ?? 400) >= 600;
    final large = fontSize >= 24 || (bold && fontSize >= 18.67);
    final required = isIcon || large ? 3.0 : 4.5;
    final back = background(rect);
    if (back == null) continue;
    final fg = Color.alphaBlend(style.color!, back);
    final ratio = contrastRatio(fg, back);
    final key = '$text|${rect.left.round()}|${rect.top.round()}';
    if (!seen.add(key)) continue;
    if (ratio < required) {
      findings.add(
        ContrastFinding(
          kind: isIcon ? 'icon' : 'text',
          label: isIcon
              ? 'U+${text.runes.first.toRadixString(16)}'
              : (text.length > 48 ? '${text.substring(0, 48)}…' : text),
          ratio: ratio,
          required: required,
          foreground: fg,
          background: back,
          rect: rect,
        ),
      );
    }
  }
  return findings;
}
