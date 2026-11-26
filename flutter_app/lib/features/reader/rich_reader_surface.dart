import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kDoubleTapTimeout, kLongPressTimeout, kPrimaryButton, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/rendering.dart' show SelectionStatus;
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../models/app_settings.dart';
import '../../models/ebook_fulltext.dart';
import '../../views/reader_chapter_content.dart';
import '../../services/reader/narration_pairing.dart';
import 'reader_document_geometry.dart';
import 'reader_page_indicator.dart';

/// One rich document surface for scrolling and measured pagination. Changing
/// chrome geometry preserves its raw offset instead of rounding to a new page.
/// A saved highlight of the chapter: [range] is in source UTF-16 offsets.
class ReaderSavedHighlight {
  const ReaderSavedHighlight({
    required this.id,
    required this.range,
    required this.color,
  });
  final String id;
  final TextRange range;
  final Color color;
}

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
    this.maxColumnWidth,
    this.onPreviousChapter,
    this.onVisibleTextOffset,
    this.onPlayFromHere,
    this.highlight,
    this.savedHighlights = const [],
    this.onHighlight,
    this.onAddNote,
this.onSetLanguage,
    this.onRemoveHighlight,
    this.initialSourceOffset = 0,
    this.followNarration = false,
    this.pairRequest = 0,
    this.onPairedChanged,
  });
  final FulltextChapter chapter;
  final int initialSourceOffset;
  final MirrorAppSettings settings;
  final Color background, foreground;
  final TextStyle bodyStyle, headingStyle;
  final VoidCallback? onCenterTap, onAutoHideChrome;
  final bool Function()? onNextChapter, onPreviousChapter;

  /// Width of the centered text column; the page and its edge zones keep the full width.
  final double? maxColumnWidth;
  final ValueChanged<int?>? onVisibleTextOffset;

  /// Offered as "Play from here" on selected text, with the source UTF-16
  /// offset of the selection start. Selection is enabled only when set.
  final ValueChanged<int>? onPlayFromHere;
  final TextRange? highlight;

  /// Saved highlights painted under the text; a selection over one offers
  /// removal instead of a new highlight.
  final List<ReaderSavedHighlight> savedHighlights;

  /// Selection actions, each given the selected source UTF-16 range.
  final ValueChanged<TextRange>? onHighlight, onAddNote, onSetLanguage;
  final ValueChanged<String>? onRemoveHighlight;

  /// "Follow spoken text": the page turns to the highlighted (spoken) sentence.
  final bool followNarration;

  /// Bumped to ask for the narrated page and to follow it again.
  final int pairRequest;

  /// Whether the page shows the spoken sentence (null: nothing is narrated).
  final ValueChanged<bool?>? onPairedChanged;

  @override
  State<RichReaderSurface> createState() => _RichReaderSurfaceState();
}

class _RichReaderSurfaceState extends State<RichReaderSurface> {
  final _content = GlobalKey();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _selection = SelectionListenerNotifier();
  ReaderDocumentGeometry? _geometry;
  Object? _signature;
  Object? _documentSignature;
  Widget? _document;
  Object? _textGeometry;
  int? _restoreSource;
  double _height = 0;
  static const _verticalPadding = 16.0;
  bool _measurementPending = false;
  final NarrationPairing _pairing = NarrationPairing();
  bool? _publishedPairing;
  bool _forceFollow = false;
  (Offset, Duration)? _tapDown;
  Timer? _mouseTap;

  /// The chapter text made selectable, with "Play from here" on a selection.
  Widget? _selectableDocument() {
    final document = _document;
    if (document == null || widget.onPlayFromHere == null) return document;
    return SelectionArea(
      contextMenuBuilder: _contextMenu,
      child: SelectionListener(selectionNotifier: _selection, child: document),
    );
  }

  Widget _contextMenu(BuildContext context, SelectableRegionState region) {
    final items = [...region.contextMenuButtonItems];
    final selected =
        _selection.registered &&
        _selection.selection.status == SelectionStatus.uncollapsed;
    if (selected) {
      final range = _selectionSourceRange();
      final overlapping = range == null
          ? null
          : widget.savedHighlights
                .where((h) => h.range.start < range.end && range.start < h.range.end)
                .firstOrNull;
      void act(VoidCallback call) {
        region.hideToolbar();
        region.clearSelection();
        call();
      }
      final t = AppLocalizations.of(context)!;
      final extras = [
        if (range != null && overlapping != null && widget.onRemoveHighlight != null)
          ContextMenuButtonItem(
            label: t.readerRemoveHighlight,
            onPressed: () => act(() => widget.onRemoveHighlight!(overlapping.id)),
          ),
        if (range != null && overlapping == null && widget.onHighlight != null)
          ContextMenuButtonItem(
            label: t.readerHighlight,
            onPressed: () => act(() => widget.onHighlight!(range)),
          ),
        if (range != null && widget.onAddNote != null)
          ContextMenuButtonItem(
            label: t.readerAddNote,
            onPressed: () => act(() => widget.onAddNote!(range)),
          ),
        if (range != null && widget.onSetLanguage != null)
          ContextMenuButtonItem(
            label: t.readerPassageLanguage,
            onPressed: () => act(() => widget.onSetLanguage!(range)),
          ),
      ];
      items.insertAll(0, extras);
      items.insert(
        0,
        ContextMenuButtonItem(
          label: AppLocalizations.of(context)!.readerPlayFromHere,
          onPressed: () {
            // Read the selection first, then leave selection mode: clear it and
            // close the action bar before playback starts from that point.
            final offset = _selectionStartOffset();
            region.hideToolbar();
            region.clearSelection();
            if (offset != null) widget.onPlayFromHere?.call(offset);
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: items,
    );
  }

  TextRange? _selectionSourceRange() {
    final range = _selection.registered ? _selection.selection.range : null;
    final geometry = _geometry;
    if (range == null || geometry == null) return null;
    final low = range.startOffset < range.endOffset ? range.startOffset : range.endOffset;
    final high = range.startOffset < range.endOffset ? range.endOffset : range.startOffset;
    final start = geometry.sourceOffsetForContentOffset(low);
    final end = geometry.sourceOffsetForContentOffset(high);
    if (start == null || end == null || end <= start) return null;
    return TextRange(start: start, end: end);
  }

  int? _selectionStartOffset() {
    final range = _selection.registered ? _selection.selection.range : null;
    if (range == null) return null;
    final start = range.startOffset < range.endOffset
        ? range.startOffset
        : range.endOffset;
    return _geometry?.sourceOffsetForContentOffset(start);
  }

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
    if (oldWidget.pairRequest != widget.pairRequest) {
      _pairing.resume();
      _forceFollow = true;
    }
    if (oldWidget.chapter.index != widget.chapter.index ||
        oldWidget.chapter.text != widget.chapter.text) {
      _geometry = null;
      _signature = null;
      _pairing.resume();
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
          final target = _paginated
              ? _pages.lastWhere(
                  (pageStart) => pageStart <= box.center.dy,
                  orElse: () => box.top,
                )
              : box.top;
          _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
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

  /// A single tap on the page: the centre toggles the chrome, the sides turn the page.
  void _tapAt(Offset position, double width) {
    if (!_paginated) {
      widget.onCenterTap?.call();
      return;
    }
    final x = position.dx / width;
    // The edge overlays below turn the page themselves.
    if (x < .18 || x > .82) return;
    if (position.dx < width * .2) {
      _turn(false);
    } else if (position.dx > width * .8) {
      _turn(true);
    } else {
      widget.onCenterTap?.call();
    }
  }

  void _turn(bool forward) {
    _pairing.suspendAfterManualTurn();
    final pages = _pages;
    if (pages.isEmpty && _scroll.hasClients) {
      // Fell back to scrolling (a fragment taller than the page, Apple #1391):
      // an edge tap moves one screen with a line of overlap; only at either
      // end does it go to the neighbouring chapter.
      final position = _scroll.position;
      final line = (widget.bodyStyle.fontSize ?? 18) *
          (widget.bodyStyle.height ?? 1.5);
      final step = math.max(_height - line, _height / 2);
      final atEnd = forward
          ? _scroll.offset >= position.maxScrollExtent - 0.5
          : _scroll.offset <= position.minScrollExtent + 0.5;
      if (atEnd) {
        if (forward) {
          widget.onNextChapter?.call();
        } else {
          widget.onPreviousChapter?.call();
        }
      } else {
        _scroll.jumpTo((_scroll.offset + (forward ? step : -step))
            .clamp(position.minScrollExtent, position.maxScrollExtent));
      }
      widget.onAutoHideChrome?.call();
      return;
    }
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

  /// Keeps the page on the spoken sentence (see [NarrationPairing]).
  void _followNarration() {
    final highlight = widget.highlight;
    final geometry = _geometry;
    if (highlight == null || geometry == null || !_scroll.hasClients) {
      _publishPairing(null);
      return;
    }
    final top = geometry.boxesFor(highlight).firstOrNull?.top;
    final pages = _pages;
    if (top == null || pages.isEmpty) {
      _publishPairing(null);
      return;
    }
    int pageOf(double y) {
      final index = pages.lastIndexWhere((offset) => offset <= y + 0.5);
      return index < 0 ? 0 : index;
    }

    final shown = pageOf(_offset);
    final narrated = pageOf(top);
    final target = _pairing.targetPage(
      shown: shown,
      narrated: narrated,
      follow: widget.followNarration || _forceFollow,
    );
    _forceFollow = false;
    if (target != null) {
      _scroll.jumpTo(pages[target].clamp(0, _scroll.position.maxScrollExtent));
    }
    _publishPairing(
      target != null
          ? true
          : NarrationPairing.paired(shown: shown, narrated: narrated),
    );
  }

  void _publishPairing(bool? paired) {
    if (paired == _publishedPairing) return;
    _publishedPairing = paired;
    widget.onPairedChanged?.call(paired);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final media = MediaQuery.of(context);
      final column = widget.maxColumnWidth;
      final gutter = column == null || constraints.maxWidth <= column
          ? 0.0
          : (constraints.maxWidth - column) / 2;
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
      // Whole device pixels: a half-pixel viewport edge lets the top of the next line
      // leak under the guard as a faint sliver.
      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      _height =
          ((constraints.maxHeight -
                      (widget.settings.readerShowPageNumbers && _paginated
                          ? 28
                          : 0)) *
                  pixelRatio)
              .floorToDouble() /
          pixelRatio;
      // Like the 16e, an image taller than a page is capped to the usable page height.
      final maxImageHeight = _paginated
          ? math.max(0.0, _height - 2 * _verticalPadding)
          : null;
      final documentSignature = (
        widget.chapter.html,
        widget.chapter.css,
        widget.bodyStyle,
        widget.settings.readerOverrideFontFamily,
        widget.settings.readerOverrideFontSize,
        widget.settings.readerOverrideLineSpacing,
        widget.settings.readerOverrideAlignment,
        maxImageHeight,
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
          maxImageHeight: maxImageHeight,
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _followNarration();
      });
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
              SizedBox(
                height: _height,
                // A raw pointer tap: the SelectionArea below wins the tap gesture
                // arena, so a GestureDetector tap never fired on touch (A8 2026-11-25).
                child: Listener(
                  onPointerDown: (event) {
                    // A second click of a double-click selects a word; the first one must not tap.
                    _mouseTap?.cancel();
                    _tapDown = event.buttons == kPrimaryButton
                        ? (event.localPosition, event.timeStamp)
                        : null;
                  },
                  onPointerCancel: (_) => _tapDown = null,
                  onPointerUp: (event) {
                    final down = _tapDown;
                    _tapDown = null;
                    if (down == null ||
                        (event.localPosition - down.$1).distance > kTouchSlop ||
                        event.timeStamp - down.$2 >= kLongPressTimeout) {
                      return;
                    }
                    if (event.kind == PointerDeviceKind.mouse) {
                      final position = event.localPosition;
                      _mouseTap = Timer(kDoubleTapTimeout, () => _tapAt(position, constraints.maxWidth));
                    } else {
                      _tapAt(event.localPosition, constraints.maxWidth);
                    }
                  },
                  // A swipe turns the page; a mouse drag selects text instead, as on macOS.
                  child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  supportedDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                    PointerDeviceKind.trackpad,
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
                      NotificationListener<UserScrollNotification>(
                        // Scrolling by hand (continuous layout) suspends following.
                        onNotification: (notification) {
                          if (!_paginated &&
                              notification.direction != ScrollDirection.idle) {
                            _pairing.suspendAfterManualTurn();
                          }
                          return false;
                        },
                        child: SingleChildScrollView(
                          key: const ValueKey('rich-reader-viewport'),
                          controller: _scroll,
                          physics: guarded
                              ? const NeverScrollableScrollPhysics()
                              : null,
                          child: Column(
                            children: [
                              NotificationListener<
                                SizeChangedLayoutNotification
                              >(
                                onNotification: (_) {
                                  _measure();
                                  return false;
                                },
                                child: SizeChangedLayoutNotifier(
                                  child: Padding(
                                    key: _content,
                                    padding: EdgeInsets.symmetric(
                                      horizontal: widget.settings.readerMargin + gutter,
                                      vertical: _verticalPadding,
                                    ),
                                    child: _selectableDocument(),
                                  ),
                                ),
                              ),
                              if (_paginated) SizedBox(height: _height),
                            ],
                          ),
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
                      if (widget.savedHighlights.isNotEmpty && _geometry != null)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _SavedHighlightsPainter([
                                for (final h in widget.savedHighlights)
                                  (_geometry!.boxesFor(h.range), h.color),
                              ], _offset),
                            ),
                          ),
                        ),
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
              ),
              if (_paginated && widget.settings.readerShowPageNumbers)
                SizedBox(
                  height: 28,
                  child: Center(
                    child: ReaderPageIndicator(
                      page: page < 0 ? 1 : page + 1,
                      pages: pages.isEmpty ? 1 : pages.length,
                      background: widget.background,
                      foreground: widget.foreground,
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
    _mouseTap?.cancel();
    _selection.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _SavedHighlightsPainter extends CustomPainter {
  _SavedHighlightsPainter(this.groups, this.offset);
  final List<(List<Rect>, Color)> groups;
  final double offset;
  @override
  void paint(Canvas canvas, Size size) {
    for (final (boxes, color) in groups) {
      final paint = Paint()..color = color;
      for (final box in boxes) {
        canvas.drawRect(box.shift(Offset(0, -offset)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SavedHighlightsPainter oldDelegate) => true;
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
