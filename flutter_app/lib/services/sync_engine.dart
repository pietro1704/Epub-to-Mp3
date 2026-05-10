import 'dart:async';

import '../models/ebook_fulltext.dart';

/// Pure-Dart port of `ios/.../Services/SyncEngine.swift`.
///
/// Maps a chapter audio position (seconds) to a sentence id. Two timing
/// modes: real backend `segments[]` table (preferred) or WPM estimation.
/// Default WPM 200 mirrors backend `EXPECTED_WPM`. Linear walk is fine
/// at 4Hz for sub-2K-sentence chapters.
class TimingEntry {
  const TimingEntry({
    required this.id,
    required this.startMs,
    required this.endMs,
  });
  final String id;
  final int startMs;
  final int endMs;
}

enum TimingSource { segments, wpmEstimate, empty }

class SyncEngine {
  SyncEngine({int wpm = 200}) : wpm = wpm < 60 ? 60 : wpm;

  final int wpm;
  static const double _charsPerWord = 5.0;

  List<SentenceSpan> spans = const [];
  List<TimingEntry> timing = const [];
  TimingSource source = TimingSource.empty;
  String? currentSentenceId;

  final _controller = StreamController<String?>.broadcast();
  Stream<String?> get currentSentence => _controller.stream;

  void dispose() => _controller.close();

  void load(FulltextChapter chapter, double chapterDurationSeconds) {
    spans = chapter.splitSentences();
    if (spans.isEmpty) {
      timing = const [];
      source = TimingSource.empty;
      _emit(null);
      return;
    }
    final segs = chapter.segments;
    final hasFullTiming = segs != null &&
        segs.isNotEmpty &&
        segs.every((s) => s.startMs != null && s.endMs != null);
    if (hasFullTiming) {
      final list = <TimingEntry>[];
      for (var i = 0; i < segs.length; i++) {
        final s = segs[i];
        list.add(TimingEntry(
          id: s.id ?? '${chapter.index}:$i',
          startMs: s.startMs ?? 0,
          endMs: s.endMs ?? s.startMs ?? 0,
        ));
      }
      list.sort((a, b) => a.startMs.compareTo(b.startMs));
      timing = list;
      source = TimingSource.segments;
    } else {
      timing = estimateTiming(spans, chapterDurationSeconds);
      source = TimingSource.wpmEstimate;
    }
    _emit(null);
  }

  /// Pure helper — distributes `durationSeconds` across spans by char share.
  List<TimingEntry> estimateTiming(
      List<SentenceSpan> spans, double durationSeconds) {
    if (spans.isEmpty) return const [];
    final totalChars =
        spans.fold<int>(0, (acc, s) => acc + (s.text.isEmpty ? 1 : s.text.length));
    if (totalChars <= 0) return const [];
    final double totalMs;
    if (durationSeconds > 0) {
      totalMs = durationSeconds * 1000.0;
    } else {
      final words = totalChars / _charsPerWord;
      totalMs = words / wpm * 60000.0;
    }
    final out = <TimingEntry>[];
    var cursor = 0.0;
    for (final span in spans) {
      final share =
          (span.text.isEmpty ? 1 : span.text.length) / totalChars;
      final dur = totalMs * share;
      out.add(TimingEntry(
        id: span.id,
        startMs: cursor.round(),
        endMs: (cursor + dur).round(),
      ));
      cursor += dur;
    }
    return out;
  }

  String? update(double positionSeconds) {
    if (timing.isEmpty) {
      _emit(null);
      return null;
    }
    final positionMs = (positionSeconds * 1000.0).round();
    TimingEntry? active;
    for (final e in timing) {
      if (positionMs >= e.startMs && positionMs < e.endMs) {
        active = e;
        break;
      }
    }
    if (active == null) {
      // Fallback: latest entry whose start is <= position.
      for (final e in timing) {
        if (positionMs >= e.startMs) active = e;
      }
    }
    final last = timing.last;
    if (positionMs >= last.endMs) {
      _emit(null);
      return null;
    }
    final id = active?.id;
    _emit(id);
    return id;
  }

  void _emit(String? id) {
    if (id == currentSentenceId) return;
    currentSentenceId = id;
    if (!_controller.isClosed) _controller.add(id);
  }
}
