import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../models/app_settings.dart';
import '../models/ebook_fulltext.dart';
import 'reader_typography.dart';

class ReaderHtmlChapterContent extends StatelessWidget {
  const ReaderHtmlChapterContent({
    super.key,
    required this.html,
    required this.settings,
    required this.bg,
    required this.fg,
    required this.bodyStyle,
    required this.headingStyle,
  });

  final String html;
  final AppSettings settings;
  final Color bg, fg;
  final TextStyle bodyStyle, headingStyle;

  /// HTML rendering path. Used when the chapter ships with a
  /// pre-parsed HTML body (most EPUBs). Mirrors the iOS
  /// `EpubHtmlRenderer` — applies user font / colour / alignment
  /// overrides on top of the EPUB's own typography, and caps every
  /// inherited font-size at `bodyFontSize * 1.5` so abusive heading
  /// declarations cannot blow out the page.
  ///
  /// Active-sentence highlighting + tap-to-jump are NOT supported on
  /// this path — the `Html` widget owns its own InlineSpan tree and
  /// does not expose per-sentence anchors. Switch to the span-based
  /// path (set `chapter.html` null) for sync-highlight playback.
  @override
  Widget build(BuildContext context) {
    final bodyFontSize = bodyStyle.fontSize ?? 18.0;
    final headingCap = cappedHeadingSize(bodyFontSize);
    final textAlign = flutterTextAlign(settings.readerTextAlignment);
    final bodyStyleHtml = Style(
      fontSize: FontSize(bodyFontSize),
      color: fg,
      fontFamily: bodyStyle.fontFamily,
      lineHeight: LineHeight(
        (bodyStyle.height ?? (bodyFontSize > 0 ? 1.5 : 1.5)),
      ),
      textAlign: textAlign,
      backgroundColor: bg,
    );
    final headingStyleHtml = Style(
      fontSize: FontSize(headingCap),
      color: fg,
      fontWeight: FontWeight.w600,
      fontFamily: headingStyle.fontFamily,
    );
    return Html(
      data: html,
      style: {
        'body': bodyStyleHtml,
        'p': bodyStyleHtml,
        'div': bodyStyleHtml,
        'span': bodyStyleHtml,
        'h1': headingStyleHtml,
        'h2': headingStyleHtml,
        'h3': headingStyleHtml,
        'h4': headingStyleHtml,
        'h5': headingStyleHtml,
        'h6': headingStyleHtml,
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
  final AppSettings settings;
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
