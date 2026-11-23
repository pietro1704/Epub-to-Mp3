import 'dart:async';

import 'audio_player_interface.dart';

/// Reports the book whose audio is actually audible, once each time playback
/// (re)starts or the playing book changes, so "Recently played" follows what
/// was heard rather than what was opened.
class PlaybackRecencyRecorder {
  PlaybackRecencyRecorder({
    required AudioPlayerInterface player,
    required this._bookId,
    required this._onPlayed,
  }) : _player = player {
    _playingSubscription = player.playing.listen((playing) {
      if (!playing) _armed = true;
    });
    _positionSubscription = player.position.listen((_) => _maybeRecord());
  }

  final AudioPlayerInterface _player;
  final String? Function() _bookId;
  final void Function(String bookId) _onPlayed;
  late final StreamSubscription<bool> _playingSubscription;
  late final StreamSubscription<Duration> _positionSubscription;
  bool _armed = true;
  String? _lastBookId;

  void _maybeRecord() {
    if (!_player.isPlaying) return;
    final id = _bookId() ?? _player.currentBookId;
    if (id == null) return;
    if (!_armed && id == _lastBookId) return;
    _armed = false;
    _lastBookId = id;
    _onPlayed(id);
  }

  Future<void> dispose() async {
    await _playingSubscription.cancel();
    await _positionSubscription.cancel();
  }
}
