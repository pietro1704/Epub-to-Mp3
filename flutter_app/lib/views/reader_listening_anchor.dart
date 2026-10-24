part of 'reader_view.dart';

extension _ReaderListeningAnchor on _ReaderViewState {
  void _publishListeningAnchor() {
    if (widget.onVisibleTextOffset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = ref.read(settingsProvider);
      final paginated = settings.readerLayout == ReaderLayout.paginated;
      final page = _pages.isEmpty ? null : _pages[_currentPage.clamp(0, _pages.length - 1)];
      if (paginated && (!_scrollController.hasClients || _scrollController.offset <= 0)) {
        widget.onVisibleTextOffset?.call(page?.spans.firstOrNull?.startChar);
        return;
      }
      final visibleSpans = paginated ? page?.spans ?? const <SentenceSpan>[] : widget.spans;
      final viewport = context.findRenderObject();
      if (viewport is! RenderBox || !viewport.hasSize) return;
      final top = viewport.localToGlobal(Offset.zero).dy + MediaQuery.paddingOf(context).top;
      for (final span in visibleSpans) {
        final render = _spanKeys[span.id]?.currentContext?.findRenderObject();
        RenderParagraph? paragraph(RenderObject? object) {
          if (object is RenderParagraph) return object;
          RenderParagraph? result;
          object?.visitChildren((child) { result ??= paragraph(child); });
          return result;
        }
        final text = paragraph(render);
        if (text == null || !text.hasSize) continue;
        final origin = text.localToGlobal(Offset.zero);
        if (origin.dy + text.size.height <= top) continue;
        final visible = text.getPositionForOffset(Offset(0, (top - origin.dy).clamp(0, text.size.height)));
        widget.onVisibleTextOffset?.call(span.startChar + span.text.substring(0, visible.offset).runes.length);
        return;
      }
      // Legacy HTML surfaces have no trusted raw source mapping.
      widget.onVisibleTextOffset?.call(null);
    });
  }
}
