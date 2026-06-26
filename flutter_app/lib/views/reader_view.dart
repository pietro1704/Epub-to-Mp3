import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import 'package:flutter_html/flutter_html.dart';

import '../models/ebook_fulltext.dart';
import '../services/paginator.dart';
import '../state/providers.dart';
import 'reader_theme_colors.dart';

typedef ChapterStepCallback = bool Function();

/// Maximum heading size relative to the user-chosen body font. Mirrors
/// iOS `EpubHtmlRenderer` (commit 8485ab2). Pure helper so it can be
/// unit-tested without a Flutter binding.
double cappedHeadingSize(double bodyFontSize, {double scale = 1.5}) {
  // Designed heading wants body + 6pt; the cap clamps it to bodyFontSize * scale.
  final designed = bodyFontSize + 6;
  final maximum = bodyFontSize * scale;
  return designed < maximum ? designed : maximum;
}

/// Content equality for two span lists. Mirrors the iOS reader's
/// CONTENT-vs-pointer gate (TextKitPageView.swift, commit d473109): a
/// re-render that rebuilds the spans list with fresh-but-identical
/// instances must NOT trigger a repagination/relayout (which flickers).
/// `SentenceSpan` is a freezed value type, so `==` compares by content;
/// `identical()` would return false on a freshly-built equal list and
/// fire a needless relayout. Pure helper so it can be unit-tested
/// without a Flutter binding.
bool spansContentEqual(List<SentenceSpan> a, List<SentenceSpan> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Convert the persisted `ReaderTextAlignment` enum to Flutter's
/// `TextAlign`. Default `.justified` matches Apple Books / print
/// typography.
TextAlign flutterTextAlign(ReaderTextAlignment a) {
  switch (a) {
    case ReaderTextAlignment.justified:
      return TextAlign.justify;
    case ReaderTextAlignment.left:
      return TextAlign.left;
  }
}

class ReaderView extends ConsumerStatefulWidget {
  final FulltextChapter chapter;
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
  late List<ReaderPage> _pages;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _spanKeys = {};
  String? _lastScrolledTo;

  @override
  void initState() {
    super.initState();
    _committedChapterToken = widget.chapter.index;
    _pages = Paginator.paginate(spans: widget.spans);
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
      _pages = Paginator.paginate(spans: widget.spans);
      _currentPage = 0;
      _committedChapterToken = token;
    } else if (!spansContentEqual(oldWidget.spans, widget.spans)) {
      // Same chapter, genuinely different content (e.g. settings-driven
      // re-split). Repaginate but keep the reader near its current page.
      // Gating on CONTENT equality (not list identity) mirrors iOS
      // d473109: a parent rebuild that hands a fresh-but-identical
      // spans list must NOT trigger a relayout/flicker.
      _pages = Paginator.paginate(spans: widget.spans);
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
    final settings = ref.watch(settingsProvider);
    final bg = ReaderThemeColors.background(settings.readerTheme,
        custom: settings.readerCustomColors);
    final fg = ReaderThemeColors.foreground(settings.readerTheme,
        custom: settings.readerCustomColors);
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
        context, settings, bg, fg, bodyStyle, headingStyle, margin,
      );
    }
    return _paginatedLayout(
      context, settings, bg, fg, bodyStyle, headingStyle, margin,
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
                ? _htmlBody(html, settings, bg, fg, bodyStyle, headingStyle)
                : _spanBody(
                    settings, fg, bodyStyle, headingStyle, activeId),
          ),
        ),
      ),
    );
  }

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
  Widget _htmlBody(
    String html,
    AppSettings settings,
    Color bg,
    Color fg,
    TextStyle bodyStyle,
    TextStyle headingStyle,
  ) {
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

  /// Plain-text span fallback. Used when the chapter has no HTML
  /// body or when the user wants sync-highlight playback. Renders
  /// each `SentenceSpan` as its own `Text` so the active sentence
  /// can be highlighted and tapped to jump.
  Widget _spanBody(
    AppSettings settings,
    Color fg,
    TextStyle bodyStyle,
    TextStyle headingStyle,
    String? activeId,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _chapterHeader(headingStyle, fg),
        const SizedBox(height: 12),
        ...widget.spans.map((s) {
          final isActive = s.id == activeId;
          return Padding(
            key: _spanKeys.putIfAbsent(s.id, () => GlobalKey()),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: GestureDetector(
              onTap: () => widget.onJumpToSentence?.call(s),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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

  /// Width of each side tap zone in the paginated layout. Sized at
  /// 22% of the screen width so on a 360 pt-wide Android phone the
  /// tap target is ~80 pt — well above the 44 pt HIG minimum — and
  /// on a 1080 pt-wide tablet it scales to ~240 pt without dwarfing
  /// the text. Mirrors the iOS three-zone partition where each zone
  /// is one-third of the screen, but uses overlays instead of
  /// Expanded children so the text underneath stretches edge-to-edge.
  double _tapZoneWidth(BuildContext context) =>
      MediaQuery.of(context).size.width * 0.22;

  Widget _paginatedLayout(
    BuildContext context,
    AppSettings settings,
    Color bg,
    Color fg,
    TextStyle bodyStyle,
    TextStyle headingStyle,
    double margin,
  ) {
    final page = _pages.isEmpty
        ? const ReaderPage(<SentenceSpan>[])
        : _pages[_currentPage.clamp(0, _pages.length - 1)];
    final pageIndex = _pages.isEmpty
        ? 0
        : _currentPage.clamp(0, _pages.length - 1);

    // Safe area is an INVIOLABLE floor. Mirrors iOS `topCorridor`
    // (ReaderLayoutMath.swift, commit fbe8ea3): when the host hides
    // the reader chrome the top toolbar (which provided the SafeArea
    // top) disappears, and the first line would render under the
    // status bar / notch. Add the system top/bottom insets on top of
    // the reader's own breathing pad so text always clears the notch
    // and the home indicator, chrome shown or hidden.
    final media = MediaQuery.of(context);
    const readerVerticalPad = 24.0;
    final topPad = media.padding.top + readerVerticalPad;
    final bottomPad = media.padding.bottom + readerVerticalPad;

    return Container(
      color: bg,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v < -200) {
              advancePage();
            } else if (v > 200) {
              retreatPage();
            }
          },
          child: Stack(
            children: [
              // Text body fills the FULL width of the page area (minus
              // the user's `readerMargin` horizontal inset). The
              // page-turn tap zones live as transparent overlays on
              // the left and right edges so the text silhouette is
              // as wide as the screen. Prior layout used
              // `Expanded(flex: 1)` / `Expanded(flex: 2)` /
              // `Expanded(flex: 1)`, which gave each tap zone 25% of
              // the screen and the text only 50% — user-reported on
              // Android 2026-05-22 as "margens laterais muito
              // grandes". Mirrors the iOS `tapZones` overlay
              // partition (see ReaderView.swift).
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onCenterTap,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.only(
                      left: margin,
                      right: margin,
                      top: topPad,
                      bottom: bottomPad,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (pageIndex == 0)
                          _chapterHeader(headingStyle, fg),
                        ...page.spans.map((s) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 2),
                              child: GestureDetector(
                                onTap: () =>
                                    widget.onJumpToSentence?.call(s),
                                child: Text(
                                  s.text,
                                  style: bodyStyle,
                                  textAlign: flutterTextAlign(
                                      settings.readerTextAlignment),
                                ),
                              ),
                            )),
                      ],
                    ),
                  ),
                ),
              ),
              // Left page-turn zone — 22% of width, transparent
              // overlay. `behavior: opaque` so the tap doesn't bubble
              // through to the underlying text/centre-tap detector.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _tapZoneWidth(context),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: retreatPage,
                ),
              ),
              // Right page-turn zone — mirror image of the left zone.
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: _tapZoneWidth(context),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: advancePage,
                ),
              ),
              // Page footer — hidden when the user disables page numbers.
              if (_pages.isNotEmpty && settings.readerShowPageNumbers)
                Positioned(
                  bottom: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: fg.withValues(alpha: 0.1),
                      ),
                      child: Text(
                        '${pageIndex + 1} / ${_pages.length}',
                        style: TextStyle(
                          fontSize: 11,
                          color: fg.withValues(alpha: 0.5),
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

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

class ChapterAdvanceModel {
  int currentChapterIndex;
  final int chapterCount;

  ChapterAdvanceModel({
    required this.currentChapterIndex,
    required this.chapterCount,
  });

  bool advance() {
    if (currentChapterIndex + 1 >= chapterCount) return false;
    currentChapterIndex += 1;
    return true;
  }

  bool retreat() {
    if (currentChapterIndex <= 0) return false;
    currentChapterIndex -= 1;
    return true;
  }
}
