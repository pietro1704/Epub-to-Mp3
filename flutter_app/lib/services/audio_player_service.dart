import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../models/job_snapshot.dart';

/// just_audio wrapper. Builds a `ConcatenatingAudioSource` from a job's
/// playable chapters. audio_service integration is deferred to the
/// caller so this stays unit-testable.
class AudioPlayerService {
  AudioPlayerService({String? backendBase}) : _baseUrl = backendBase;

  final AudioPlayer _player = AudioPlayer();
  final String? _baseUrl;
  List<ChapterProgress> _chapters = const [];

  Stream<Duration> get position => _player.positionStream;
  Stream<bool> get playing => _player.playingStream;
  Stream<int?> get currentIndex => _player.currentIndexStream;
  AudioPlayer get raw => _player;

  Future<void> setQueue(List<ChapterProgress> chapters) async {
    _chapters = chapters;
    final base = _baseUrl ?? '';
    final children = <AudioSource>[
      for (final c in chapters)
        if (c.downloadUrl != null)
          AudioSource.uri(_resolve(base, c.downloadUrl!)),
    ];
    if (children.isEmpty) return;
    await _player.setAudioSource(
      ConcatenatingAudioSource(children: children),
      preload: false,
    );
  }

  Uri _resolve(String base, String urlOrPath) {
    if (urlOrPath.startsWith('http')) return Uri.parse(urlOrPath);
    final cleanBase = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanPath = urlOrPath.startsWith('/') ? urlOrPath : '/$urlOrPath';
    return Uri.parse('$cleanBase$cleanPath');
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration position, {int? index}) =>
      _player.seek(position, index: index);
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  Future<void> dispose() => _player.dispose();

  List<ChapterProgress> get chapters => _chapters;
}
