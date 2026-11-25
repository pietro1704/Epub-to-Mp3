import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../models/app_settings.dart';
import '../models/ebook_fulltext.dart';
import 'reader_typography.dart';

/// Link colour that meets WCAG AA (4.5:1) on [background] (Apple #1501): the system
/// link blue keeps its hue and is darkened or lightened only until it passes.
Color readerLinkColor(Color background) {
  final dark = background.computeLuminance() < 0.18;
  final base = HSLColor.fromColor(
    dark ? const Color(0xff0a84ff) : const Color(0xff007aff),
  );
  double ratio(Color c) {
    final a = c.computeLuminance(), b = background.computeLuminance();
    return ((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05);
  }

  if (ratio(base.toColor()) >= 4.5) return base.toColor();
  for (final lighten in dark ? [true, false] : [false, true]) {
    for (var step = 1; step <= 100; step++) {
      final l = lighten
          ? base.lightness + (1 - base.lightness) * step / 100
          : base.lightness * (1 - step / 100);
      final candidate = base.withLightness(l.clamp(0.0, 1.0)).toColor();
      if (ratio(candidate) >= 4.5) return candidate;
    }
  }
  return dark ? Colors.white : Colors.black;
}

/// Drops `height: N%` declarations from book CSS. Against an auto-height parent a
/// percentage height computes to auto, but flutter_html lays it out as zero, which
/// hid e.g. a book's full-page map (`.style20 { height: 95% }`).
String withoutPercentHeights(String css) => css.replaceAll(
  RegExp(
    r'(?<![\w-])height\s*:\s*[\d.]+%\s*(!important)?\s*;?',
    caseSensitive: false,
  ),
  '',
);

class ReaderHtmlChapterContent extends StatelessWidget {
  const ReaderHtmlChapterContent({
    super.key,
    required this.html,
    this.css,
    this.onLinkTap,
    required this.settings,
    required this.bg,
    required this.fg,
    required this.bodyStyle,
    required this.headingStyle,
  });

  final String html;
  final String? css;
  final ValueChanged<String?>? onLinkTap;
  final MirrorAppSettings settings;
  final Color bg, fg;
  final TextStyle bodyStyle, headingStyle;

  /// Shared rich content for scrolling and measured pagination. Explicit
  /// reader choices override source CSS; otherwise its typography survives.
  @override
  Widget build(BuildContext context) {
    final bodyFontSize = bodyStyle.fontSize ?? 18.0;
    final headingCap = cappedHeadingSize(bodyFontSize);
    final textAlign = flutterTextAlign(settings.readerTextAlignment);
    final bodyStyleHtml = Style(
      fontSize: settings.readerOverrideFontSize ? FontSize(bodyFontSize) : null,
      color: fg,
      fontFamily: settings.readerOverrideFontFamily
          ? bodyStyle.fontFamily
          : null,
      lineHeight: settings.readerOverrideLineSpacing
          ? LineHeight(bodyStyle.height ?? 1.5)
          : null,
      textAlign: settings.readerOverrideAlignment ? textAlign : null,
      backgroundColor: bg,
    );
    final headingStyleHtml = Style(
      fontSize: settings.readerOverrideFontSize ? FontSize(headingCap) : null,
      color: fg,
      fontFamily: settings.readerOverrideFontFamily
          ? headingStyle.fontFamily
          : null,
    );
    final bookCss = css == null ? null : withoutPercentHeights(css!);
    final sourceStyles = bookCss == null
        ? <String, Style>{}
        : Style.fromCss(bookCss, null);
    return Html(
      data: bookCss == null ? html : '<style>$bookCss</style>$html',
      onLinkTap: (url, _, _) => onLinkTap?.call(url),
      style: {
        ...sourceStyles,
        'body': (sourceStyles['body'] ?? Style()).merge(bodyStyleHtml),
        'p': (sourceStyles['p'] ?? Style()).merge(bodyStyleHtml),
        'div': (sourceStyles['div'] ?? Style()).merge(bodyStyleHtml),
        'span': (sourceStyles['span'] ?? Style()).merge(bodyStyleHtml),
        'h1': (sourceStyles['h1'] ?? Style()).merge(headingStyleHtml),
        'h2': (sourceStyles['h2'] ?? Style()).merge(headingStyleHtml),
        'h3': (sourceStyles['h3'] ?? Style()).merge(headingStyleHtml),
        'h4': (sourceStyles['h4'] ?? Style()).merge(headingStyleHtml),
        'h5': (sourceStyles['h5'] ?? Style()).merge(headingStyleHtml),
        'h6': (sourceStyles['h6'] ?? Style()).merge(headingStyleHtml),
        'a': (sourceStyles['a'] ?? Style()).merge(
          Style(color: readerLinkColor(bg)),
        ),
      },
    );
  }
}

class ReaderSpanChapterContent extends StatelessWidget {
  const ReaderSpanChapterContent({
    super.key,
    required this.spans,
    required this.settings,
    required this.fg,
    required this.bodyStyle,
    required this.header,
    required this.activeId,
    required this.spanKeys,
    this.onJumpToSentence,
  });

  final List<SentenceSpan> spans;
  final MirrorAppSettings settings;
  final Color fg;
  final TextStyle bodyStyle;
  final Widget header;
  final String? activeId;
  final Map<String, GlobalKey> spanKeys;
  final ValueChanged<SentenceSpan>? onJumpToSentence;

  /// Plain-text span fallback. Used when the chapter has no HTML
  /// body or when the user wants sync-highlight playback. Renders
  /// each `SentenceSpan` as its own `Text` so the active sentence
  /// can be highlighted and tapped to jump.
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 12),
        ...spans.map((s) {
          final isActive = s.id == activeId;
          return Padding(
            key: spanKeys.putIfAbsent(s.id, () => GlobalKey()),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: GestureDetector(
              onTap: () => onJumpToSentence?.call(s),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  color: isActive
                      ? Colors.yellow.withValues(alpha: 0.35)
                      : Colors.transparent,
                ),
                child: Text(
                  s.text,
                  style: bodyStyle,
                  textAlign: flutterTextAlign(settings.readerTextAlignment),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}
