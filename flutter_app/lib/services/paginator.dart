// Mirror of ios/EpubToMp3/EpubToMp3/Services/Paginator.swift @ 1f20d54
// Source of truth: SwiftUI. Update via the flutter-mirror agent.
//
// Minimal Dart counterpart: groups consecutive sentence spans into
// fixed-size pages by character budget. Pixel-accurate measurement
// stays platform-specific — Flutter callers should use a TextPainter
// + LayoutBuilder for the production reader. This pure function is
// enough to pin paginated-mode chapter-advance behaviour in tests.

import '../models/ebook_fulltext.dart';

class ReaderPage {
  final List<SentenceSpan> spans;
  const ReaderPage(this.spans);
}

class Paginator {
  /// Greedy character-budget pagination. Mirrors the Swift contract
  /// (`Paginator.paginate(spans:pageSize:fontSize:...)`) at the level
  /// of behaviour we want to lock down: same input → same number of
  /// pages, last page may be short.
  static List<ReaderPage> paginate({
    required List<SentenceSpan> spans,
    int pageSize = 1500,
  }) {
    if (spans.isEmpty) return const [];
    final pages = <ReaderPage>[];
    var current = <SentenceSpan>[];
    var currentLen = 0;
    for (final s in spans) {
      final len = s.text.length + 1;
      if (current.isNotEmpty && currentLen + len > pageSize) {
        pages.add(ReaderPage(List.unmodifiable(current)));
        current = <SentenceSpan>[];
        currentLen = 0;
      }
      current.add(s);
      currentLen += len;
    }
    if (current.isNotEmpty) {
      pages.add(ReaderPage(List.unmodifiable(current)));
    }
    return pages;
  }
}
