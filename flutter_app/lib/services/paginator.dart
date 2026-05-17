// Mirror of ios/EpubToMp3/EpubToMp3/Services/Paginator.swift @ 1f20d54
// Source of truth: SwiftUI. Update via the flutter-mirror agent.
//
// Word-boundary-aware paginator. Joins all text with paragraph breaks,
// then splits at paragraph > sentence > word boundaries. Never cuts
// mid-word. Pure function — no Flutter dependencies.

import '../models/ebook_fulltext.dart';

class ReaderPage {
  final List<SentenceSpan> spans;
  const ReaderPage(this.spans);
}

/// Regex patterns for boundary detection.
final _sentenceEnd = RegExp(r'[.!?][""”)]*\s');
final _wordBoundary = RegExp(r'\s');

class Paginator {
  /// Paginate spans respecting word boundaries. Mirrors the iOS approach:
  /// join all text, split at paragraph > sentence > word boundaries.
  /// Never cuts mid-word.
  static List<ReaderPage> paginate({
    required List<SentenceSpan> spans,
    int pageSize = 1500,
  }) {
    if (spans.isEmpty) return const [];

    // Build combined text with paragraph breaks between spans.
    final combined = spans.map((s) => s.text).join('\n\n');

    // Split the combined text into pages at appropriate boundaries.
    final pageTexts = _splitAtBoundaries(combined, pageSize);

    // Map page texts back to span groups.
    return _mapTextToSpanPages(pageTexts, spans);
  }

  /// Split text into chunks of at most [budget] characters, cutting at
  /// paragraph > sentence > word boundaries. Never cuts mid-word.
  static List<String> _splitAtBoundaries(String text, int budget) {
    if (text.isEmpty) return const [];
    if (text.length <= budget) return [text];

    final pages = <String>[];
    var remaining = text;

    while (remaining.isNotEmpty) {
      if (remaining.length <= budget) {
        pages.add(remaining);
        break;
      }

      // Find best cut point within budget.
      final cutPoint = _findCutPoint(remaining, budget);
      pages.add(remaining.substring(0, cutPoint).trimRight());
      remaining = remaining.substring(cutPoint).trimLeft();
    }

    return pages;
  }

  /// Find the best position to cut [text] at or before [budget].
  /// Priority: paragraph break > sentence end > word boundary.
  static int _findCutPoint(String text, int budget) {
    final window = text.substring(0, budget);

    // 1. Try paragraph break (double newline) — search backwards from budget.
    final paraIdx = window.lastIndexOf('\n\n');
    if (paraIdx > budget ~/ 4) {
      return paraIdx + 2; // After the double newline.
    }

    // 2. Try sentence boundary — last sentence-ending punctuation followed by space.
    final sentenceMatches = _sentenceEnd.allMatches(window).toList();
    if (sentenceMatches.isNotEmpty) {
      final last = sentenceMatches.last;
      if (last.end > budget ~/ 4) {
        return last.end;
      }
    }

    // 3. Try word boundary — last whitespace.
    final wordIdx = window.lastIndexOf(_wordBoundary);
    if (wordIdx > budget ~/ 4) {
      return wordIdx + 1;
    }

    // 4. Fallback: hard cut at budget (shouldn't happen with real text).
    return budget;
  }

  /// Map page text chunks back to groups of original SentenceSpan objects.
  /// Each page gets the spans whose text appears in that page's portion.
  static List<ReaderPage> _mapTextToSpanPages(
      List<String> pageTexts, List<SentenceSpan> spans) {
    if (pageTexts.isEmpty) return const [];

    final pages = <ReaderPage>[];
    var spanIdx = 0;
    var charConsumed = 0;

    // Calculate cumulative positions of each span in the combined text.
    // Combined = span[0].text + "\n\n" + span[1].text + "\n\n" + ...
    final spanStarts = <int>[];
    final spanEnds = <int>[];
    var pos = 0;
    for (var i = 0; i < spans.length; i++) {
      spanStarts.add(pos);
      pos += spans[i].text.length;
      spanEnds.add(pos);
      if (i < spans.length - 1) pos += 2; // "\n\n" separator
    }
    final totalLen = pos;

    // Assign spans to pages based on character budget consumption.
    for (final pageText in pageTexts) {
      final pageLen = pageText.length;
      // Account for trimmed whitespace between pages.
      final pageEndChar = charConsumed + pageLen;

      final pageSpans = <SentenceSpan>[];
      while (spanIdx < spans.length && spanStarts[spanIdx] < pageEndChar) {
        pageSpans.add(spans[spanIdx]);
        spanIdx++;
      }

      if (pageSpans.isNotEmpty) {
        pages.add(ReaderPage(List.unmodifiable(pageSpans)));
      }

      // Advance consumed position past any separator whitespace.
      charConsumed = pageEndChar;
      // Skip separator chars that were trimmed.
      if (charConsumed < totalLen) {
        // The trimLeft/trimRight in _splitAtBoundaries may eat separators.
        // Advance to the start of the next span still unassigned.
        if (spanIdx < spans.length) {
          charConsumed = spanStarts[spanIdx];
        }
      }
    }

    // Any remaining spans go into a final page.
    if (spanIdx < spans.length) {
      final remaining = <SentenceSpan>[];
      while (spanIdx < spans.length) {
        remaining.add(spans[spanIdx]);
        spanIdx++;
      }
      pages.add(ReaderPage(List.unmodifiable(remaining)));
    }

    return pages;
  }
}
