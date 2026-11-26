import '../services/ui_trace.dart';
import '../services/reader/narration_pairing.dart';
import '../models/reader_listening_position.dart';
import '../features/reader/rich_reader_surface.dart';
import '../features/reader/reader_page_indicator.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';

import '../models/ebook_fulltext.dart';
import '../models/bookmark.dart';
import '../l10n/app_localizations.dart';
import '../services/reader/viewport_paginator.dart';

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
  final int initialSourceOffset;
  final TextRange? measuredHighlight;
  final ValueChanged<int?>? onVisibleTextOffset;

  /// Source UTF-16 offset chosen with "Play from here" on selected text.
  final ValueChanged<int>? onPlayFromHere;

  /// Enables saved highlights and notes on selected text for this book.
  final String? bookId;
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
    this.initialSourceOffset = 0,
    this.measuredHighlight,
    this.onVisibleTextOffset,
    this.onPlayFromHere,
    this.bookId,
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
  bool _usesPaginatedSurface = false;
  int? _visibleSourceAnchor;
  final FocusNode _focusNode = FocusNode();
  final NarrationPairing _pairing = NarrationPairing();
  bool? _publishedPairing;
  bool _forceFollow = false;
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _spanKeys = {};
  String? _lastScrolledTo;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_publishListeningAnchor);
    _committedChapterToken = widget.chapter.index;
    _visibleSourceAnchor = widget.initialSourceOffset;
    _pageLayoutKey = null;
    UiTrace.instance.emit('reader.chapter', {
      'index': widget.chapter.index,
      'name': widget.chapter.name,
      'head': widget.chapter.text.trimLeft(),
    });
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
      _visibleSourceAnchor = widget.spans.firstOrNull?.startChar;
      _usesPaginatedSurface = false;
      // Chapter swap. Re-seed from the FRESH pages and commit the new
      // token. Resetting to page 0 here (rather than carrying a stale
      // index) is what stops the "wrong interleaved page" flash where
      // the previous chapter's content was shown during the new
      // chapter's repagination window (iOS d069e9a).
      _pageLayoutKey = null;
      _currentPage = 0;
      _committedChapterToken = token;
      _pairing.resume();
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

  /// Turns to [page] without it counting as a manual turn (narration following).
  void _showPage(int page) => setState(() => _currentPage = page);

  void advancePage() {
    _pairing.suspendAfterManualTurn();
    if (_currentPage + 1 < _pages.length) {
      setState(() => _currentPage += 1);
    } else {
      widget.onAdvanceChapter?.call();
    }
    widget.onAutoHideChrome?.call();
  }

  void retreatPage() {
    _pairing.suspendAfterManualTurn();
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
    // "Go to the narrated page": resume following even if it is switched off.
    ref.listen(readerPairRequestProvider, (_, _) {
      _pairing.resume();
      _forceFollow = true;
      if (mounted) setState(() {});
    });
    final settings = ref.watch(
      readerSettingsProvider(ref.watch(currentlyReadingBookIdProvider)),
    );
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

    if (widget.chapter.html?.trim().isNotEmpty == true) {
      return SafeArea(
        child: RichReaderSurface(
              chapter: widget.chapter,
              maxColumnWidth: settings.readerColumnWidth,
              highlight: _richHighlight(),
              initialSourceOffset: widget.initialSourceOffset,
              settings: settings,
              background: bg,
              foreground: fg,
              bodyStyle: bodyStyle,
              headingStyle: headingStyle,
              onVisibleTextOffset: widget.onVisibleTextOffset,
              onPlayFromHere: widget.onPlayFromHere,
              savedHighlights: _savedHighlights(),
              onHighlight: widget.bookId == null ? null : _saveHighlight,
              onAddNote: widget.bookId == null ? null : _saveNote,
              onRemoveHighlight: widget.bookId == null
                  ? null
                  : ref.read(bookmarkStoreProvider).remove,
              onCenterTap: widget.onCenterTap,
              onAutoHideChrome: widget.onAutoHideChrome,
              onNextChapter: widget.onAdvanceChapter,
              onPreviousChapter: widget.onPreviousChapter,
              followNarration: settings.readerAutoScroll,
              pairRequest: ref.watch(readerPairRequestProvider),
              onPairedChanged: (paired) =>
                  ref.read(readerNarrationPairedProvider.notifier).state =
                      paired,
        ),
      );
    }
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
    _usesPaginatedSurface = false;
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
              // The theme's own text color: a translucent tint of it is 2.4:1 on sepia.
              style: TextStyle(fontSize: 12, color: fg),
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  List<ReaderSavedHighlight> _savedHighlights() {
    final book = widget.bookId;
    if (book == null) return const [];
    return [
      for (final h in ref
          .watch(bookmarkStoreProvider)
          .bookmarksForChapter(book, widget.chapter.index)
          .where((b) => b.isHighlight))
        ReaderSavedHighlight(
          id: h.id,
          range: TextRange(start: h.startChar, end: h.endChar),
          color: _highlightColor(h.color),
        ),
    ];
  }

  static Color _highlightColor(HighlightColor color) => switch (color) {
    HighlightColor.yellow => const Color(0x66ffcc00),
    HighlightColor.blue => const Color(0x6642a5f5),
    HighlightColor.green => const Color(0x6666bb6a),
    HighlightColor.pink => const Color(0x66f06292),
    HighlightColor.orange => const Color(0x66ff9800),
  };

  Bookmark? _saveHighlight(TextRange range) {
    final book = widget.bookId;
    final text = widget.chapter.text;
    if (book == null || range.end > text.length) return null;
    return ref.read(bookmarkStoreProvider).addBookmark(
      bookId: book,
      chapterIndex: widget.chapter.index,
      chapterTitle: widget.chapter.displayTitle,
      startChar: range.start,
      endChar: range.end,
      selectedText: text.substring(range.start, range.end),
    );
  }

  Future<void> _saveNote(TextRange range) async {
    final controller = TextEditingController();
    final t = AppLocalizations.of(context)!;
    final note = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(t.readerAddNote),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: InputDecoration(hintText: t.addNoteHint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(t.cancel)),
          TextButton(
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: Text(t.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null || note.isEmpty) return;
    final saved = _saveHighlight(range);
    if (saved != null) ref.read(bookmarkStoreProvider).updateNote(saved.id, note);
  }

  TextRange? _richHighlight() {
    if (widget.measuredHighlight != null) return widget.measuredHighlight;
    final span = widget.spans
        .where((span) => span.id == widget.currentSentenceId)
        .firstOrNull;
    if (span == null) return null;
    try {
      final start = ReaderListeningPosition.fromDisplayScalar(
        0,
        widget.chapter.text,
        span.startChar,
      ).textOffset;
      final end = span.endChar.clamp(start, widget.chapter.text.runes.length);
      return TextRange(
        start: String.fromCharCodes(widget.chapter.text.runes.take(start))
            .length,
        end: String.fromCharCodes(widget.chapter.text.runes.take(end)).length,
      );
    } on FormatException {
      return null;
    }
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
