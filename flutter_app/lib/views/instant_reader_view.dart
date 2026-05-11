// Mirror of ios/EpubToMp3/EpubToMp3/Views/InstantReaderView.swift @ 1f20d54
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

  const InstantReaderView({
    super.key,
    required this.fulltext,
    this.initialChapterIndex = 0,
  });

  @override
  State<InstantReaderView> createState() => _InstantReaderViewState();
}

class _InstantReaderViewState extends State<InstantReaderView> {
  late int _currentChapterIndex;

  @override
  void initState() {
    super.initState();
    _currentChapterIndex = widget.initialChapterIndex;
  }

  /// Returns `true` if there *is* a next chapter and we advanced.
  /// Called from [ReaderView] when the user pages past the last page
  /// of the current chapter — without this, paginated mode dead-ends
  /// after page 1 of chapter 0 and the rest of the book is invisible.
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
    final chapters = widget.fulltext.chapters;
    if (_currentChapterIndex < 0 || _currentChapterIndex >= chapters.length) {
      return Center(child: Text('No chapter at index $_currentChapterIndex.'));
    }
    final chapter = chapters[_currentChapterIndex];
    final spans = chapter.splitSentences();
    return ReaderView(
      chapter: chapter,
      spans: spans,
      onAdvanceChapter: advanceToNextChapter,
      onPreviousChapter: returnToPreviousChapter,
    );
  }
}
