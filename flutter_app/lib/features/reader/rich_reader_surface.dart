import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_settings.dart';
import '../../models/ebook_fulltext.dart';
import '../../views/reader_chapter_content.dart';
import 'reader_document_geometry.dart';

/// One rich document surface for scrolling and measured pagination. Changing
/// chrome geometry preserves its raw offset instead of rounding to a new page.
class RichReaderSurface extends StatefulWidget {
  const RichReaderSurface({
    super.key,
    required this.chapter,
    required this.settings,
    required this.background,
    required this.foreground,
    required this.bodyStyle,
    required this.headingStyle,
    this.onCenterTap,
    this.onAutoHideChrome,
    this.onNextChapter,
    this.onPreviousChapter,
    this.onVisibleTextOffset,
    this.highlight,
    this.initialSourceOffset = 0,
  });
  final FulltextChapter chapter;
  final int initialSourceOffset;
  final MirrorAppSettings settings;
  final Color background, foreground;
  final TextStyle bodyStyle, headingStyle;
  final VoidCallback? onCenterTap, onAutoHideChrome;
  final bool Function()? onNextChapter, onPreviousChapter;
  final ValueChanged<int?>? onVisibleTextOffset;
  final TextRange? highlight;

  @override
  State<RichReaderSurface> createState() => _RichReaderSurfaceState();
}

class _RichReaderSurfaceState extends State<RichReaderSurface> {
  final _content = GlobalKey();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  ReaderDocumentGeometry? _geometry;
  Object? _signature;
  Object? _documentSignature;
  Widget? _document;
  Object? _textGeometry;
  int? _restoreSource;
  double _height = 0;
  bool _measurementPending = false;

  bool get _paginated => widget.settings.readerLayout == ReaderLayout.paginated;
  List<double> get _pages => _geometry?.pageOffsets(_height) ?? const [0];
  double get _offset => _scroll.hasClients ? _scroll.offset : 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_positionChanged);
    _restoreSource = widget.initialSourceOffset > 0
        ? _utf16Offset(widget.initialSourceOffset)
        : null;
  }

  @override
  void didUpdateWidget(covariant RichReaderSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapter.index != widget.chapter.index ||
        oldWidget.chapter.text != widget.chapter.text) {
      _geometry = null;
      _signature = null;
      _restoreSource = widget.initialSourceOffset > 0
          ? _utf16Offset(widget.initialSourceOffset)
          : null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  int _utf16Offset(int scalar) =>
      String.fromCharCodes(widget.chapter.text.runes.take(scalar)).length;

  void _positionChanged() {
    if (!mounted) return;
    final utf16 = _geometry?.sourceOffsetAt(_offset);
    final scalar = utf16 == null
        ? null
        : widget.chapter.text
              .substring(0, utf16.clamp(0, widget.chapter.text.length))
              .runes
              .length;
    widget.onVisibleTextOffset?.call(scalar);
    setState(() {});
  }

  void _measure() {
    if (_measurementPending) return;
    _measurementPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementPending = false;
      if (!mounted) return;
      final render = _content.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return;
      setState(
        () => _geometry = ReaderDocumentGeometry.measure(
          render,
          widget.chapter.text,
        ),
      );
      final restore = _restoreSource;
      _restoreSource = null;
      if (restore != null && _scroll.hasClients) {
        final box = _geometry!
            .boxesFor(TextRange(start: restore, end: restore + 1))
            .firstOrNull;
        if (box != null) {
          _scroll.jumpTo(box.top.clamp(0, _scroll.position.maxScrollExtent));
        }
      }
      final utf16 = _geometry?.sourceOffsetAt(_offset);
      widget.onVisibleTextOffset?.call(
        utf16 == null
            ? null
            : widget.chapter.text.substring(0, utf16).runes.length,
      );
    });
  }

  void _turn(bool forward) {
    final pages = _pages;
    final target = forward
        ? pages.where((offset) => offset > _offset + 0.5).firstOrNull
        : pages.reversed.where((offset) => offset < _offset - 0.5).firstOrNull;
    if (target == null) {
      if (forward) {
        widget.onNextChapter?.call();
      } else {
        widget.onPreviousChapter?.call();
      }
    } else if (_scroll.hasClients) {
      _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    }
    widget.onAutoHideChrome?.call();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final textGeometry = (
        constraints.maxWidth,
        widget.bodyStyle.fontSize,
        widget.bodyStyle.fontFamily,
        widget.bodyStyle.height,
        widget.settings.readerOverrideFontSize,
        widget.settings.readerOverrideFontFamily,
        widget.settings.readerOverrideLineSpacing,
        widget.settings.readerMargin,
        media.textScaler,
      );
      if (_textGeometry != null && _textGeometry != textGeometry) {
        _restoreSource = _geometry?.sourceOffsetAt(_offset);
      }
      _textGeometry = textGeometry;
      final documentSignature = (
        widget.chapter.html,
        widget.chapter.css,
        widget.bodyStyle,
        widget.settings.readerOverrideFontFamily,
        widget.settings.readerOverrideFontSize,
        widget.settings.readerOverrideLineSpacing,
        widget.settings.readerOverrideAlignment,
      );
      if (_documentSignature != documentSignature) {
        _documentSignature = documentSignature;
        _document = ReaderHtmlChapterContent(
          html: widget.chapter.html!,
          css: widget.chapter.css,
          settings: widget.settings,
          bg: widget.background,
          fg: widget.foreground,
          bodyStyle: widget.bodyStyle,
          headingStyle: widget.headingStyle,
        );
      }
      final signature = (
        constraints.biggest,
        widget.chapter.html,
        widget.bodyStyle,
        widget.settings.readerMargin,
        media.textScaler,
        widget.settings.readerLayout,
      );
      if (_signature != signature) {
        _signature = signature;
        _measure();
      }
      _height =
          constraints.maxHeight -
          (widget.settings.readerShowPageNumbers && _paginated ? 28 : 0);
      final pages = _pages;
      final guarded = _paginated && pages.isNotEmpty;
      final (top, bottom) = guarded
          ? _geometry?.edgeGuards(_offset, _height) ?? (0.0, 0.0)
          : (0.0, 0.0);
      final page = pages.lastIndexWhere((offset) => offset <= _offset + 0.5);
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent || !_paginated) {
            return KeyEventResult.ignored;
          }
          if ([
            LogicalKeyboardKey.arrowRight,
            LogicalKeyboardKey.pageDown,
            LogicalKeyboardKey.space,
          ].contains(event.logicalKey)) {
            _turn(true);
            return KeyEventResult.handled;
          }
          if ([
            LogicalKeyboardKey.arrowLeft,
            LogicalKeyboardKey.pageUp,
          ].contains(event.logicalKey)) {
            _turn(false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: ColoredBox(
          color: widget.background,
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    if (!_paginated) {
                      widget.onCenterTap?.call();
                      return;
                    }
                    if (details.localPosition.dx < constraints.maxWidth * .2) {
                      _turn(false);
                    } else if (details.localPosition.dx >
                        constraints.maxWidth * .8) {
                      _turn(true);
                    } else {
                      widget.onCenterTap?.call();
                    }
                  },
                  onHorizontalDragEnd: _paginated
                      ? (details) {
                          final velocity = details.primaryVelocity ?? 0;
                          if (velocity.abs() > 150) {
                            _turn(velocity < 0);
                          }
                        }
                      : null,
                  child: Stack(
                    children: [
                      SingleChildScrollView(
                        key: const ValueKey('rich-reader-viewport'),
                        controller: _scroll,
                        physics: guarded
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        child: Column(
                          children: [
                            NotificationListener<SizeChangedLayoutNotification>(
                              onNotification: (_) {
                                _measure();
                                return false;
                              },
                              child: SizeChangedLayoutNotifier(
                                child: Padding(
                                  key: _content,
                                  padding: EdgeInsets.symmetric(
                                    horizontal: widget.settings.readerMargin,
                                    vertical: 16,
                                  ),
                                  child: _document,
                                ),
                              ),
                            ),
                            if (_paginated) SizedBox(height: _height),
                          ],
                        ),
                      ),
                      if (_paginated) ...[
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: constraints.maxWidth * .18,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _turn(false),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          width: constraints.maxWidth * .18,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _turn(true),
                          ),
                        ),
                      ],
                      if (widget.highlight != null && _geometry != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _ReaderHighlightPainter(
                                _geometry!.boxesFor(widget.highlight!),
                                _offset,
                              ),
                            ),
                          ),
                        ),
                      if (top > 0)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: top,
                          child: IgnorePointer(
                            child: ColoredBox(color: widget.background),
                          ),
                        ),
                      if (bottom > 0)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          height: bottom,
                          child: IgnorePointer(
                            child: ColoredBox(color: widget.background),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_paginated && widget.settings.readerShowPageNumbers)
                SizedBox(
                  height: 28,
                  child: Center(
                    child: Text(
                      '${page < 0 ? 1 : page + 1} / ${pages.isEmpty ? 1 : pages.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.foreground.withValues(alpha: .6),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _ReaderHighlightPainter extends CustomPainter {
  _ReaderHighlightPainter(this.boxes, this.offset);
  final List<Rect> boxes;
  final double offset;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0x55ffcc00);
    for (final box in boxes) {
      canvas.drawRect(box.shift(Offset(0, -offset)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ReaderHighlightPainter oldDelegate) => true;
}
