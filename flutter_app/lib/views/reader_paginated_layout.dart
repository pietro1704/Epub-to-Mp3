part of 'reader_view.dart';

extension _ReaderPaginatedLayout on _ReaderViewState {
  Widget _paginatedLayout(BuildContext context, AppSettings settings, Color bg,
      Color fg, TextStyle bodyStyle, TextStyle headingStyle, double margin) {
    return LayoutBuilder(builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final inheritedStyle = DefaultTextStyle.of(context).style;
      bodyStyle = inheritedStyle.merge(bodyStyle);
      headingStyle = inheritedStyle.merge(headingStyle);
      final direction = Directionality.of(context);
      final width = constraints.maxWidth - 2 * margin;
      final height = constraints.maxHeight - media.padding.vertical - 48;
      double measure(String text, TextStyle style) {
        final painter = TextPainter(text: TextSpan(text: text, style: style),
          textDirection: direction, textScaler: media.textScaler)..layout(maxWidth: width);
        final result = painter.height;
        painter.dispose();
        return result;
      }
      final header = measure(widget.chapter.displayTitle, headingStyle) + 12 +
          (widget.chapter.charCount == null ? 0 : 4 + measure(
            '${widget.chapter.charCount} characters', inheritedStyle.merge(const TextStyle(fontSize: 12))));
      final key = (width, height, bodyStyle, media.textScaler, direction, header);
      if (_pageLayoutKey != key) {
        final anchor = _pages.isEmpty || _pages[_currentPage.clamp(0, _pages.length - 1)].spans.isEmpty
            ? 0 : _pages[_currentPage.clamp(0, _pages.length - 1)].spans.first.startChar;
        try {
          final pages = ViewportPaginator.paginate(spans: widget.spans, width: width,
            height: height, style: bodyStyle, textScaler: media.textScaler,
            direction: direction, firstPageHeaderHeight: header);
          _pages = pages;
          final matching = pages.indexWhere((page) => page.spans.any(
            (span) => span.startChar <= anchor && anchor < span.endChar));
          _currentPage = matching < 0 ? 0 : matching;
          _pageLayoutKey = key;
        } on StateError {
          // An impossibly small viewport still exposes every glyph by scrolling.
          return _scrollingLayout(context, settings, bg, fg, bodyStyle, headingStyle, margin);
        }
      }
      return _renderPaginatedLayout(context, settings, bg, fg, bodyStyle, headingStyle, margin);
    });
  }

  Widget _renderPaginatedLayout(
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
                        if (pageIndex == 0) _chapterHeader(headingStyle, fg),
                        ...page.spans.map(
                          (s) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: GestureDetector(
                              onTap: () => widget.onJumpToSentence?.call(s),
                              child: Text(
                                s.text,
                                style: bodyStyle,
                                textAlign: flutterTextAlign(
                                  settings.readerTextAlignment,
                                ),
                              ),
                            ),
                          ),
                        ),
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
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: fg.withValues(alpha: 0.1),
                      ),
                      child: Text(
                        '${pageIndex + 1} / ${_pages.length}',
                        style: TextStyle(
                          fontSize: 11,
                          color: fg.withValues(alpha: 0.5),
                          fontFeatures: const [FontFeature.tabularFigures()],
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

}
