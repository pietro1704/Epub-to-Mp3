// Mirror of ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift @ 9fc413a
// Source of truth: SwiftUI. Update via the flutter-mirror agent.
//
// Host view around [ReaderView]. Owns `currentChapterIndex` and wires
// the advance/retreat callbacks so the paginated reader can cross
// chapter boundaries (Carl Sagan dead-end fix).

import 'package:flutter/material.dart';

import '../models/ebook_fulltext.dart';
import 'reader_view.dart';

class InstantReaderView extends StatefulWidget {
  final EbookFulltext fulltext;
  final int initialChapterIndex;
  final String? statusBanner;
  final VoidCallback? onRequestPlay;

  const InstantReaderView({
    super.key,
    required this.fulltext,
    this.initialChapterIndex = 0,
    this.statusBanner,
    this.onRequestPlay,
  });

  @override
  State<InstantReaderView> createState() => _InstantReaderViewState();
}

class _InstantReaderViewState extends State<InstantReaderView> {
  late int _currentChapterIndex;

  static const _minReadableChars = 10;

  List<Chapter> get _readableChapters => widget.fulltext.chapters
      .where((c) => c.text.trim().length >= _minReadableChars)
      .toList();

  int get _firstReadableIndex {
    final idx = widget.fulltext.chapters.indexWhere(
      (c) => c.text.trim().length >= _minReadableChars,
    );
    return idx >= 0 ? idx : 0;
  }

  Chapter? _resolveChapter(int index) {
    final chapters = widget.fulltext.chapters;
    // Try index+1 match (1-based), then exact, then array position.
    final candidates = [
      chapters.cast<Chapter?>().firstWhere(
            (c) => c!.index == index + 1,
            orElse: () => null,
          ),
      chapters.cast<Chapter?>().firstWhere(
            (c) => c!.index == index,
            orElse: () => null,
          ),
      if (index >= 0 && index < chapters.length) chapters[index],
    ];
    for (final c in candidates) {
      if (c != null && c.text.trim().length >= _minReadableChars) return c;
    }
    return candidates.whereType<Chapter>().firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.initialChapterIndex == 0
        ? _firstReadableIndex
        : widget.initialChapterIndex;
  }

  bool advanceToNextChapter() {
    if (_currentChapterIndex + 1 >= widget.fulltext.chapters.length) {
      return false;
    }
    setState(() => _currentChapterIndex += 1);
    return true;
  }

  bool returnToPreviousChapter() {
    if (_currentChapterIndex <= 0) return false;
    setState(() => _currentChapterIndex -= 1);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final chapter = _resolveChapter(_currentChapterIndex);
    if (chapter == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text('No content available',
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    final spans = chapter.splitSentences();
    return Column(
      children: [
        Expanded(
          child: ReaderView(
            chapter: chapter,
            spans: spans,
            onAdvanceChapter: advanceToNextChapter,
            onPreviousChapter: returnToPreviousChapter,
          ),
        ),
        _buildBottomBar(context, chapter),
      ],
    );
  }

  Widget _buildBottomBar(BuildContext context, Chapter chapter) {
    final theme = Theme.of(context);
    final banner = widget.statusBanner;
    final isConverting = banner != null && banner.isNotEmpty;
    final isError = isConverting &&
        (banner!.toLowerCase().contains('failed') ||
            banner.toLowerCase().contains('unavailable'));

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withOpacity(0.3),
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: theme.colorScheme.primary.withOpacity(0.1),
              ),
              child: Icon(Icons.headphones,
                  color: theme.colorScheme.primary, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    chapter.displayTitle,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isConverting)
                    Row(
                      children: [
                        if (isError)
                          Icon(Icons.warning_amber_rounded,
                              size: 14, color: Colors.orange[700])
                        else
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child:
                                CircularProgressIndicator(strokeWidth: 1.5),
                          ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            banner!,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.hintColor),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  else if (widget.fulltext.bookAuthor != null)
                    Text(
                      widget.fulltext.bookAuthor!,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.hintColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (!isConverting && widget.onRequestPlay != null)
              IconButton(
                icon: const Icon(Icons.play_circle_filled, size: 36),
                onPressed: widget.onRequestPlay,
              ),
          ],
        ),
      ),
    );
  }
}
