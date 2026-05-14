import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ebook_fulltext.dart';
import '../state/providers.dart';
import '../views/reader_theme_colors.dart';

class ReaderView extends ConsumerStatefulWidget {
  const ReaderView({
    super.key,
    required this.jobId,
    required this.chapter,
  });

  final String jobId;
  final FulltextChapter chapter;

  @override
  ConsumerState<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<ReaderView> {
  final _controller = ScrollController();
  final Map<String, GlobalKey> _spanKeys = {};
  String? _lastScrolledTo;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final spans = widget.chapter.splitSentences();
    final activeId =
        ref.watch(currentSentenceProvider(widget.jobId)).valueOrNull;
    final bg = ReaderThemeColors.background(settings.readerTheme,
        custom: settings.readerCustomColors);
    final fg = ReaderThemeColors.foreground(settings.readerTheme,
        custom: settings.readerCustomColors);
    final fontSize = settings.readerPointSize;
    final lineSpacing = settings.readerLineSpacing;
    final margin = settings.readerMargin.clamp(16.0, 80.0);

    if (activeId != null && activeId != _lastScrolledTo) {
      _lastScrolledTo = activeId;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(activeId));
    }

    return Container(
      color: bg,
      child: Scrollbar(
        controller: _controller,
        child: SingleChildScrollView(
          controller: _controller,
          padding: EdgeInsets.symmetric(horizontal: margin, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.chapter.name != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    widget.chapter.name!,
                    style: TextStyle(
                      fontSize: fontSize + 6,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                ),
              ...spans.map((span) => _Sentence(
                    key: _spanKeys.putIfAbsent(span.id, () => GlobalKey()),
                    span: span,
                    fontSize: fontSize,
                    lineHeight: 1.4 + (lineSpacing / 20.0),
                    isActive: span.id == activeId,
                    textColor: fg,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  void _scrollTo(String id) {
    final key = _spanKeys[id];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 250),
        alignment: 0.3,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _Sentence extends StatelessWidget {
  const _Sentence({
    super.key,
    required this.span,
    required this.fontSize,
    required this.lineHeight,
    required this.isActive,
    required this.textColor,
  });

  final SentenceSpan span;
  final double fontSize;
  final double lineHeight;
  final bool isActive;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: isActive
          ? BoxDecoration(
              color: Colors.yellow.withOpacity(0.35),
              borderRadius: BorderRadius.circular(6),
            )
          : null,
      child: Text(
        span.text,
        style: TextStyle(
          fontSize: fontSize,
          height: lineHeight,
          color: textColor,
        ),
      ),
    );
  }
}
