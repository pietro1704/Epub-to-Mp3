import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';

import '../models/ebook_fulltext.dart';
import '../services/paginator.dart';
import '../services/viewport_paginator.dart';

import '../state/providers.dart';
import 'reader_theme_colors.dart';
import 'reader_typography.dart';
import 'reader_chapter_content.dart';

export 'reader_typography.dart';
export 'chapter_advance_model.dart';

part 'reader_paginated_layout.dart';
part 'reader_listening_anchor.dart';

typedef ChapterStepCallback = bool Function();

class ReaderView extends ConsumerStatefulWidget {
  final FulltextChapter chapter;
  final ValueChanged<int?>? onVisibleTextOffset;
  final List<SentenceSpan> spans;
  final String? currentSentenceId;
  final void Function(SentenceSpan)? onJumpToSentence;
  final ChapterStepCallback? onAdvanceChapter;
  final ChapterStepCallback? onPreviousChapter;

  /// Called when the user taps the center zone of the reader. Used by
  /// the hosting screen to toggle chrome visibility (AppBar + player bar).
  final VoidCallback? onCenterTap;

  /// Called whenever the user turns a page (tap zone, keyboard, or
  /// swipe). The host screen should dim its chrome (AppBar, player
  /// bar, status bar) for an immersive reading experience. Mirrors
  /// iOS PlayerReaderView page-turn dim behaviour.
  final VoidCallback? onAutoHideChrome;

  const ReaderView({
    super.key,
    required this.chapter,
    this.onVisibleTextOffset,
    required this.spans,
    this.currentSentenceId,
    this.onJumpToSentence,
    this.onAdvanceChapter,
    this.onPreviousChapter,
    this.onCenterTap,
    this.onAutoHideChrome,
  });

  @override
  ConsumerState<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<ReaderView> {
  int _currentPage = 0;
  List<ReaderPage> _pages = const [];
  Object? _pageLayoutKey;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _spanKeys = {};
  String? _lastScrolledTo;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_publishListeningAnchor);
    _committedChapterToken = widget.chapter.index;
    _pageLayoutKey = null;
  }

  /// The chapter the currently-displayed `_pages` were paginated from.
  /// Mirrors the iOS `committedChapterToken` latch (TextKitPageView.swift,
  /// commits 6ab6609 / d069e9a): the page swap is driven deterministically
  /// off the chapter id, not off a page-count delta (two adjacent chapters
  /// can share a count) nor list pointer identity. When the token changes
  /// we repaginate and re-seed to page 0 exactly once, so the new chapter's
  /// first page is shown once and never preceded by a stale frame.
  late int _committedChapterToken;

  @override
  void didUpdateWidget(covariant ReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final token = widget.chapter.index;
    if (token != _committedChapterToken) {
      // Chapter swap. Re-seed from the FRESH pages and commit the new
      // token. Resetting to page 0 here (rather than carrying a stale
      // index) is what stops the "wrong interleaved page" flash where
      // the previous chapter's content was shown during the new
      // chapter's repagination window (iOS d069e9a).
      _pageLayoutKey = null;
      _currentPage = 0;
      _committedChapterToken = token;
    } else if (!spansContentEqual(oldWidget.spans, widget.spans)) {
      // Same chapter, genuinely different content (e.g. settings-driven
      // re-split). Repaginate but keep the reader near its current page.
      // Gating on CONTENT equality (not list identity) mirrors iOS
      // d473109: a parent rebuild that hands a fresh-but-identical
      // spans list must NOT trigger a relayout/flicker.
      _pageLayoutKey = null;
      if (_currentPage >= _pages.length) {
        _currentPage = _pages.isEmpty ? 0 : _pages.length - 1;
      }
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void advancePage() {
    if (_currentPage + 1 < _pages.length) {
      setState(() => _currentPage += 1);
    } else {
      widget.onAdvanceChapter?.call();
    }
    widget.onAutoHideChrome?.call();
  }

  void retreatPage() {
    if (_currentPage > 0) {
      setState(() => _currentPage -= 1);
    } else {
      widget.onPreviousChapter?.call();
    }
    widget.onAutoHideChrome?.call();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.pageUp ||
        k == LogicalKeyboardKey.keyK) {
      retreatPage();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.keyJ) {
      advancePage();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.home) {
      setState(() => _currentPage = 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.end) {
      setState(() {
        _currentPage = _pages.isEmpty ? 0 : _pages.length - 1;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    _publishListeningAnchor();
    final settings = ref.watch(settingsProvider);
    final bg = ReaderThemeColors.background(
      settings.readerTheme,
      custom: settings.readerCustomColors,
    );
    final fg = ReaderThemeColors.foreground(
      settings.readerTheme,
      custom: settings.readerCustomColors,
    );
    final fontSize = settings.readerPointSize;
    final lineSpacing = settings.readerLineSpacing;
    final margin = settings.readerMargin.clamp(16.0, 80.0);

    final bodyStyle = TextStyle(
      fontSize: fontSize,
      color: fg,
      height: 1.4 + (lineSpacing / 20.0),
      fontFamily: _fontFamily(settings.readerFontFamily),
    );

    // Cap heading size at 1.5x the body font. Mirrors iOS
    // `EpubHtmlRenderer` (8485ab2): some EPUBs declare `h1` at 2.5em+
    // which renders as 40-60pt and overflows the paginated page on
    // mobile. 1.5x keeps the heading visually distinct without
    // breaking pagination.
    final headingStyle = TextStyle(
      fontSize: cappedHeadingSize(fontSize),
      color: fg,
      fontWeight: FontWeight.w600,
      fontFamily: _fontFamily(settings.readerFontFamily),
    );

    if (settings.readerLayout == ReaderLayout.scrolling) {
      return _scrollingLayout(
        context,
        settings,
        bg,
        fg,
        bodyStyle,
        headingStyle,
        margin,
      );
    }
    return _paginatedLayout(
      context,
      settings,
      bg,
      fg,
      bodyStyle,
      headingStyle,
      margin,
    );
  }

  Widget _scrollingLayout(
    BuildContext context,
    AppSettings settings,
    Color bg,
    Color fg,
    TextStyle bodyStyle,
    TextStyle headingStyle,
    double margin,
  ) {
    final activeId = widget.currentSentenceId;
    if (activeId != null &&
        activeId != _lastScrolledTo &&
        settings.readerAutoScroll) {
      _lastScrolledTo = activeId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = _spanKeys[activeId];
        final ctx = key?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 350),
            alignment: 0.3,
          );
        }
      });
    }

    final html = widget.chapter.html;
    final hasHtml = html != null && html.trim().isNotEmpty;

    // Safe area as an inviolable floor — see `_paginatedLayout`. When
    // chrome hides, the top toolbar's SafeArea goes with it, so honour
    // the system insets here too (iOS fbe8ea3).
    final media = MediaQuery.of(context);
    const scrollVerticalPad = 16.0;

    return GestureDetector(
      onTap: widget.onCenterTap,
      behavior: HitTestBehavior.translucent,
      child: Container(
        // Paint the reader theme background behind the WHOLE scroll
        // region — not just behind the (content-sized) scroll child.
        // Mirrors iOS 371b204: `continuousBookScroll` got
        // `.background(themeBackground.ignoresSafeArea())` so a chapter
        // shorter than the viewport, or the overscroll-stretch zone on a
        // fast fling, never exposes the white system background. Without
        // the `width/height: infinity` the Container shrink-wraps the
        // SingleChildScrollView and a short chapter leaves a white strip
        // below the text.
        width: double.infinity,
        height: double.infinity,
        color: bg,
        child: Scrollbar(
          controller: _scrollController,
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: EdgeInsets.only(
              left: margin,
              right: margin,
              top: media.padding.top + scrollVerticalPad,
              bottom: media.padding.bottom + scrollVerticalPad,
            ),
            child: hasHtml
                ? ReaderHtmlChapterContent(
                    html: html,
                    settings: settings,
                    bg: bg,
                    fg: fg,
                    bodyStyle: bodyStyle,
                    headingStyle: headingStyle,
                  )
                : ReaderSpanChapterContent(
                    spans: widget.spans,
                    settings: settings,
                    fg: fg,
                    bodyStyle: bodyStyle,
                    header: _chapterHeader(headingStyle, fg),
                    activeId: activeId,
                    spanKeys: _spanKeys,
                    onJumpToSentence: widget.onJumpToSentence,
                  ),
          ),
        ),
      ),
    );
  }

  /// Width of each side tap zone in the paginated layout. Sized at
  /// 22% of the screen width so on a 360 pt-wide Android phone the
  /// tap target is ~80 pt — well above the 44 pt HIG minimum — and
  /// on a 1080 pt-wide tablet it scales to ~240 pt without dwarfing
  /// the text. Mirrors the iOS three-zone partition where each zone
  /// is one-third of the screen, but uses overlays instead of
  /// Expanded children so the text underneath stretches edge-to-edge.
  double _tapZoneWidth(BuildContext context) =>
      MediaQuery.of(context).size.width * 0.22;

  Widget _chapterHeader(TextStyle headingStyle, Color fg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.chapter.displayTitle, style: headingStyle),
        if (widget.chapter.charCount != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${widget.chapter.charCount} characters',
              style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.5)),
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  String? _fontFamily(ReaderFontFamily family) {
    switch (family) {
      case ReaderFontFamily.serif:
        return 'serif';
      case ReaderFontFamily.sans:
        return null;
      case ReaderFontFamily.mono:
        return 'monospace';
    }
  }
}
