import '../../models/reader_listening_position.dart';

/// Where a new listening job starts after the narration model changes, or
/// `null` when nothing is playing: the choice is then only saved and the next
/// listen captures it.
ReaderListeningPosition? narrationSwitchRestartPosition({
  required ReaderListeningPosition? position,
  required bool listening,
  required bool supportsPositionedStart,
}) => listening && supportsPositionedStart ? position : null;
