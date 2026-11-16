import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../models/app_settings.dart';
import '../models/ebook_fulltext.dart';
import 'reader_typography.dart';

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
    final sourceStyles = css == null
        ? <String, Style>{}
        : Style.fromCss(css!, null);
    return Html(
      data: css == null ? html : '<style>$css</style>$html',
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
