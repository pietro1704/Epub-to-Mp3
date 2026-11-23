import 'dart:ui' show TextRange;

import '../../models/ebook_fulltext.dart';
import '../../models/reader_listening_position.dart';

/// Where a new listening job starts after the narration model changes, or
/// `null` when nothing is playing: the choice is then only saved and the next
/// listen captures it.
///
/// The sentence being read wins; otherwise audio that is already playing wins over the reader's visible page, which
/// can still show an earlier chapter. Inside the playing chapter the reader's
/// offset is kept because the reader follows playback.
ReaderListeningPosition? narrationSwitchRestartPosition({
  ReaderListeningPosition? sentence,
  required ReaderListeningPosition? position,
  required int? playingChapter,
  required bool listening,
  required bool supportsPositionedStart,
}) {
  if (!listening || !supportsPositionedStart) return null;
  // The sentence being read is the exact point to resume from.
  if (sentence != null) return sentence;
  if (playingChapter == null) return position;
  if (position != null && position.chapterIndex == playingChapter) {
    return position;
  }
  return ReaderListeningPosition(playingChapter, 0);
}

/// Exact source position of the sentence being spoken in [chapter]: the
/// measured speech range when alignment exists, otherwise the live sentence.
/// Returns null when neither is known or does not fit the chapter text.
/// [position] is the chapter's place in the book (the axis of the audio queue
/// and of listening starts), not the parser's `FulltextChapter.index`.
ReaderListeningPosition? liveSentenceStart({
  required FulltextChapter chapter,
  required int position,
  required TextRange? measured,
  required String? liveSentenceId,
}) {
  try {
    if (measured != null) {
      // The measured range is the spoken word; resume at its sentence start.
      final word = ReaderListeningPosition.fromUtf16(
        position,
        chapter.text,
        measured.start,
      );
      var start = word;
      for (final span in chapter.splitSentences()) {
        final candidate = ReaderListeningPosition.fromDisplayScalar(
          position,
          chapter.text,
          span.startChar,
        );
        if (candidate.textOffset > word.textOffset) break;
        start = candidate;
      }
      return start;
    }
    final span = chapter
        .splitSentences()
        .where((candidate) => candidate.id == liveSentenceId)
        .firstOrNull;
    if (span == null) return null;
    return ReaderListeningPosition.fromDisplayScalar(
      position,
      chapter.text,
      span.startChar,
    );
  } on FormatException {
    return null;
  }
}

/// Last resort when the audio carries no alignment and no live sentence is
/// known: the sentence that sits at the same fraction of the chapter text as
/// [seconds] sits in the chapter audio. Returns null for unknown durations.
ReaderListeningPosition? estimatedSentenceStart({
  required FulltextChapter chapter,
  required int position,
  required double seconds,
  required double durationSeconds,
}) {
  if (!seconds.isFinite ||
      !durationSeconds.isFinite ||
      seconds < 0 ||
      durationSeconds <= 0) {
    return null;
  }
  final spans = chapter.splitSentences();
  if (spans.isEmpty) return null;
  final total = spans.last.endChar;
  final target = (total * (seconds / durationSeconds).clamp(0.0, 0.999)).floor();
  var chosen = spans.first;
  for (final span in spans) {
    if (span.startChar > target) break;
    chosen = span;
  }
  try {
    return ReaderListeningPosition.fromDisplayScalar(
      position,
      chapter.text,
      chosen.startChar,
    );
  } on FormatException {
    return null;
  }
}

/// Typical speech rate of the narration, in text scalars per second of audio at
/// 1.0x (playback speed does not change the audio file, only how fast it plays).
const double kSpeechScalarsPerSecond = 15;

/// Where synthesis restarts when a skip lands outside the audio that already
/// exists (a chapter that is still being synthesized cannot be sought).
///
/// [startSourceOffset] is where this chapter's audio started, in source
/// scalars (0 for a job that began at the chapter start); [targetSeconds] is the
/// requested media time inside that audio. The text position is estimated from
/// the voice speed and snapped to a sentence start. Returns null when the target
/// falls beyond the chapter text: the skip then continues into the next chapter.
ReaderListeningPosition? skipRestartPosition({
  required FulltextChapter chapter,
  required int position,
  required int startSourceOffset,
  required double targetSeconds,
  double scalarsPerSecond = kSpeechScalarsPerSecond,
}) {
  if (!targetSeconds.isFinite || scalarsPerSecond <= 0) return null;
  final spans = chapter.splitSentences();
  if (spans.isEmpty) return null;
  final startDisplay = _displayScalarForSource(chapter.text, startSourceOffset);
  final target = (startDisplay + scalarsPerSecond * targetSeconds).floor();
  if (target >= spans.last.endChar) return null;
  var chosen = spans.first;
  for (final span in spans) {
    if (span.startChar > target) break;
    chosen = span;
  }
  try {
    return ReaderListeningPosition.fromDisplayScalar(
      position,
      chapter.text,
      chosen.startChar,
    );
  } on FormatException {
    return null;
  }
}

/// Inverse of the source->display mapping used by
/// [ReaderListeningPosition.fromDisplayScalar].
int _displayScalarForSource(String source, int sourceOffset) {
  final raw = source.runes.toList();
  var display = 0;
  for (var index = 0; index < raw.length && index < sourceOffset; index++) {
    if (raw[index] == 0x0D && index + 1 < raw.length && raw[index + 1] == 0x0A) {
      continue;
    }
    display++;
    if (raw[index] == 0xFFFE) display++;
  }
  return display;
}
