import 'dart:async';
import 'dart:ui' show TextRange;

import '../../services/audio_player_interface.dart';
import 'measured_speech_alignment.dart';

/// One binding belongs to one exact reader book and source chapter. Async
/// metadata reads are discarded when the audible player item changes.
class MeasuredPlaybackBinding {
  MeasuredPlaybackBinding({
    required this.player,
    required this.bookId,
    required this.chapterIndex,
    required this.source,
    Future<MeasuredSpeechAlignment> Function(Uri)? read,
  }) : _read = read ?? MeasuredSpeechAlignment.read {
    _subscriptions.add(
      player.position.listen(
        (position) => update(position.inMicroseconds / 1e6),
      ),
    );
    _subscriptions.add(
      player.currentIndex.listen((_) => update(player.positionSeconds)),
    );
  }
  final AudioPlayerInterface player;
  final String bookId;
  final int chapterIndex;
  final String source;
  final Future<MeasuredSpeechAlignment> Function(Uri) _read;
  final _changes = StreamController<TextRange?>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Stream<TextRange?> get changes => _changes.stream;
  MeasuredSpeechAlignment _alignment = MeasuredSpeechAlignment([]);
  Uri? _item;
  int _generation = 0;
  bool _disposed = false;
  TextRange? _last;

  void update(double seconds) {
    if (_disposed) return;
    final index = player.currentIndexValue;
    final queueIndex = index == null
        ? -1
        : player.chapterIndexForPlayerIndex(index);
    final sourceIndex = queueIndex >= 0 && queueIndex < player.chapters.length
        ? player.chapters[queueIndex].index
        : null;
    final uri =
        index == null ||
            sourceIndex != chapterIndex ||
            player.currentBookId != bookId
        ? null
        : player.currentAudioUri;
    if (uri != _item) {
      _item = uri;
      _alignment = MeasuredSpeechAlignment([]);
      final generation = ++_generation;
      _emit(null);
      if (uri != null) {
        _read(uri).then(
          (alignment) {
            if (!_disposed &&
                generation == _generation &&
                uri == player.currentAudioUri) {
              _alignment = alignment;
              update(player.positionSeconds);
            }
          },
          onError: (Object _) {
            /* Missing metadata keeps sentence-only playback. */
          },
        );
      }
    }
    _emit(player.isLoading ? null : _alignment.rangeAt(seconds, source));
  }

  void _emit(TextRange? range) {
    if (_last == range || _disposed) return;
    _last = range;
    _changes.add(range);
  }

  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _changes.close();
  }
}
