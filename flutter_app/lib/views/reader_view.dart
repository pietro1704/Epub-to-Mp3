// Mirror of ios/EpubToMp3/EpubToMp3/Views/ReaderView.swift @ 1f20d54
// Source of truth: SwiftUI. Update via the flutter-mirror agent.
//
// Paginated reader that delegates past-the-edge navigation to the
// host view via [onAdvanceChapter] / [onPreviousChapter]. Both
// callbacks return bool: true if the host swapped chapters, false
// to keep the user pinned on the current page (last-of-book or
// first-of-book).
//
// Carl Sagan dead-end fix: every navigation entry point (tap, swipe,
// keyboard) routes through [advancePage] / [retreatPage], which fall
// through to the callback at the chapter boundary.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/ebook_fulltext.dart';
import '../services/paginator.dart';

typedef ChapterStepCallback = bool Function();

class ReaderView extends StatefulWidget {
  final FulltextChapter chapter;
  final List<SentenceSpan> spans;
  final String? currentSentenceId;
  final void Function(SentenceSpan)? onJumpToSentence;

  /// Called when the user pages past the last page of the current
  /// chapter. Should return `true` if there *is* a next chapter and
  /// the host swapped it in; `false` keeps the reader on the last
  /// page. When the host changes `chapter`, [didUpdateWidget] resets
  /// `_currentPage` to 0.
  final ChapterStepCallback? onAdvanceChapter;

  /// Same contract as [onAdvanceChapter] in the reverse direction.
  final ChapterStepCallback? onPreviousChapter;

  const ReaderView({
    super.key,
    required this.chapter,
    required this.spans,
    this.currentSentenceId,
    this.onJumpToSentence,
    this.onAdvanceChapter,
    this.onPreviousChapter,
  });

  @override
  State<ReaderView> createState() => _ReaderViewState();
}

class _ReaderViewState extends State<ReaderView> {
  int _currentPage = 0;
  late List<ReaderPage> _pages;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _pages = Paginator.paginate(spans: widget.spans);
  }

  @override
  void didUpdateWidget(covariant ReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapter.index != widget.chapter.index) {
      _pages = Paginator.paginate(spans: widget.spans);
      _currentPage = 0;
    } else if (oldWidget.spans != widget.spans) {
      _pages = Paginator.paginate(spans: widget.spans);
      if (_currentPage >= _pages.length) {
        _currentPage = _pages.isEmpty ? 0 : _pages.length - 1;
      }
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Forward navigation in paginated mode. Within the chapter, walks
  /// `_currentPage` forward; on the last page, delegates to the host
  /// via [widget.onAdvanceChapter] so the next chapter loads.
  void advancePage() {
    if (_currentPage + 1 < _pages.length) {
      setState(() => _currentPage += 1);
    } else {
      widget.onAdvanceChapter?.call();
      // Caller swapped chapter; _currentPage resets via didUpdateWidget.
    }
  }

  void retreatPage() {
    if (_currentPage > 0) {
      setState(() => _currentPage -= 1);
    } else {
      widget.onPreviousChapter?.call();
    }
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
    final page = _pages.isEmpty
        ? const ReaderPage(<SentenceSpan>[])
        : _pages[_currentPage.clamp(0, _pages.length - 1)];
    return Focus(
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
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: retreatPage,
                child: const SizedBox.expand(),
              ),
            ),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.chapter.displayTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    ...page.spans.map((s) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: GestureDetector(
                            onTap: () => widget.onJumpToSentence?.call(s),
                            child: Text(
                              s.text,
                              style: TextStyle(
                                fontWeight: s.id == widget.currentSentenceId
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        )),
                  ],
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: advancePage,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pure-Dart counterpart to the Swift `AdvanceModel` test helper.
/// Mirrors `InstantReaderView.advanceToNextChapter` /
/// `returnToPreviousChapter` so paginated chapter-boundary behaviour
/// can be regression-tested without mounting a widget tree.
class ChapterAdvanceModel {
  int currentChapterIndex;
  final int chapterCount;

  ChapterAdvanceModel({
    required this.currentChapterIndex,
    required this.chapterCount,
  });

  /// Returns true if there is a next chapter and we advanced.
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
