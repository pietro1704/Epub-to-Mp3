import '../../models/reader_listening_position.dart';

/// Where a new listening job starts after the narration model changes, or
/// `null` when nothing is playing: the choice is then only saved and the next
/// listen captures it.
///
/// Audio that is already playing wins over the reader's visible page, which
/// can still show an earlier chapter. Inside the playing chapter the reader's
/// offset is kept because the reader follows playback.
ReaderListeningPosition? narrationSwitchRestartPosition({
  required ReaderListeningPosition? position,
  required int? playingChapter,
  required bool listening,
  required bool supportsPositionedStart,
}) {
  if (!listening || !supportsPositionedStart) return null;
  if (playingChapter == null) return position;
  if (position != null && position.chapterIndex == playingChapter) {
    return position;
  }
  return ReaderListeningPosition(playingChapter, 0);
}
