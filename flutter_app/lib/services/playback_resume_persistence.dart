import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_player_service.dart';
import 'resume_store.dart';

/// Saves the active local queue position while the app is playing or leaving
/// the foreground, so a rebuilt queue can resume after a process restart.
class PlaybackResumePersistence with WidgetsBindingObserver {
  PlaybackResumePersistence({
    required AudioPlayerInterface player,
    required SharedPreferences preferences,
    required String? Function() bookId,
  }) : _player = player,
       _bookId = bookId,
       _store = ResumeStore(preferences) {
    WidgetsBinding.instance.addObserver(this);
    _positionSubscription = _player.position.listen((_) {
      unawaited(save());
    });
    _playingSubscription = _player.playing.listen((playing) {
      if (!playing) unawaited(save(force: true));
    });
  }

  final AudioPlayerInterface _player;
  final String? Function() _bookId;
  final ResumeStore _store;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  Future<void>? _pendingSave;

  Future<void> save({bool force = false}) {
    if (!force && !_player.isPlaying) return Future<void>.value();
    final id = _bookId();
    final chapter = _player.currentIndexValue;
    if (id == null || chapter == null || chapter < 0) {
      return Future<void>.value();
    }
    final seconds = _player.positionSeconds;
    final previous = _pendingSave;
    final next = () async {
      if (previous != null) await previous;
      await _store.saveBookPosition(id, chapter, seconds);
    }();
    _pendingSave = next;
    return next;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(save(force: true));
    }
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    await save(force: true);
    await _positionSubscription?.cancel();
    await _playingSubscription?.cancel();
  }
}
