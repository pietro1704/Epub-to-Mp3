import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:just_audio/just_audio.dart';

import '../models/job_snapshot.dart';
import 'latency_observation.dart';
import 'growing_chapter_audio_source.dart';

import 'audio_player_interface.dart';
import 'audio_playback_state.dart';

export 'audio_player_interface.dart';
export 'fake_audio_player_service.dart';

class _GrowingChapterEntry {
  _GrowingChapterEntry(this.source);
  final GrowingChapterAudioSource source;
  String? finalPath;
  Uri get identity => Uri(scheme: 'growing', path: source.requestId);
  bool matches(Uri uri) =>
      uri == identity || finalPath != null && uri == Uri.file(finalPath!);
}

class AudioPlayerService extends AudioPlayerInterface implements StreamingChapterPlayer {
  AudioPlayerService({String? backendBase, AudioPlayer? player})
    : _baseUrl = backendBase,
      _player = player ?? AudioPlayer() {
    _playbackState = AudioPlaybackState(_player);
  }

  final AudioPlayer _player;
  late final AudioPlaybackState _playbackState;
  @override
  PlaybackPhase get phase => _playbackState.phase;
  @override
  Stream<PlaybackPhase> get phases => _playbackState.changes;
  final String? _baseUrl;
  List<ChapterProgress> _chapters = const [];

  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<bool> get playing => phases.map((phase) => phase == PlaybackPhase.playing);
  @override
  bool get isPlaying => phase == PlaybackPhase.playing;
  @override
  bool get isLoading =>
      phase == PlaybackPhase.loading || phase == PlaybackPhase.buffering;
  @override
  Stream<int?> get currentIndex => _player.currentIndexStream;
  @override
  int? get currentIndexValue => _player.currentIndex;
  AudioPlayer get raw => _player;

  bool _isSegmentMode = false;
  int _segmentChapterIndex = -1;
  final List<String> _segmentSentenceIds = [];
  String? _activeSentenceId;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<PlayerState>? _playabilitySub;
  StreamSubscription<Duration>? _audibilitySub;
  String? _playbackJourneyId;
  String? _seekJourneyId;

  @override
  String? get activeSentenceId => _activeSentenceId;

  final _sentenceController = StreamController<String?>.broadcast();
  @override
  Stream<String?> get activeSentenceStream => _sentenceController.stream;

  @override
  Uint8List? coverArtData;

  Timer? _sleepTimer;
  double _sleepTimerRemaining = 0;
  @override
  double get sleepTimerRemaining => _sleepTimerRemaining;

  final _sleepController = StreamController<double>.broadcast();
  @override
  Stream<double> get sleepTimerStream => _sleepController.stream;

  double _speed = 1.0;
  @override
  double get speed => _speed;

  /// Maps player index → _chapters index (skipped chapters have no audio).
  List<int> _playableMap = const [];

  /// Persistent source for segment-mode appending.
  ConcatenatingAudioSource? _segmentSource;
  ConcatenatingAudioSource? _chapterSource;
  List<Uri> _chapterQueueURLs = const [];
  int _seekGeneration = 0;
  final Map<int, _GrowingChapterEntry> _growingChapters = {};

  @override
  void registerGrowingChapter(
    int chapterIndex,
    GrowingChapterAudioSource source,
  ) {
    final old = _growingChapters[chapterIndex];
    if (old != null && !old.source.isComplete) {
      old.source.fail(StateError('Chapter stream replaced'));
    }
    _growingChapters[chapterIndex] = _GrowingChapterEntry(source);
  }

  @override
  void finishGrowingChapter(int chapterIndex, String finalPath) {
    _growingChapters[chapterIndex]?.finalPath = finalPath;
  }

  @override
  Future<void> setQueue(List<ChapterProgress> chapters) async {
    _playbackState.beginRequest(_player.playerState);
    // ignore: avoid_print
    print('AudioPlayer setQueue chapters=${chapters.length} base=$_baseUrl');
    final base = _baseUrl ?? '';
    final children = <AudioSource>[];
    final map = <int>[];
    final urls = <Uri>[];
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      if (c.downloadUrl != null) {
        final growing = _growingChapters[c.index];
        final identity = Uri.parse(c.downloadUrl!);
        if (growing != null && growing.matches(identity)) {
          children.add(growing.source);
          urls.add(growing.identity);
          map.add(i);
          continue;
        }
        final url = _resolve(base, c.downloadUrl!);
        if (url.scheme.isEmpty || (url.scheme == 'http' && base.isEmpty)) {
          continue;
        }
        if (growing != null && growing.matches(url)) {
          children.add(growing.source);
          urls.add(growing.identity);
        } else {
          children.add(AudioSource.uri(url));
          urls.add(url);
        }
        map.add(i);
      }
    }
    final keepsExistingQueue =
        _chapterSource != null &&
        urls.length >= _chapterQueueURLs.length &&
        _chapterQueueURLs.asMap().entries.every(
          (entry) => urls[entry.key] == entry.value,
        );
    _chapters = chapters;
    _playableMap = map;
    // ignore: avoid_print
    print('AudioPlayer resolvedSources=${urls.length} urls=$urls');
    if (children.isEmpty) {
      _playbackState.fail();
      throw StateError('No playable audio sources were produced by Rust');
    }

    if (keepsExistingQueue) {
      for (
        var index = _chapterQueueURLs.length;
        index < children.length;
        index++
      ) {
        await _chapterSource!.add(children[index]);
      }
      _chapterQueueURLs = urls;
      return;
    }

    _isSegmentMode = false;
    _segmentSource = null;
    _chapterSource = ConcatenatingAudioSource(children: children);
    _chapterQueueURLs = urls;
    try {
      await _player.setAudioSource(_chapterSource!, preload: false);
    } catch (_) {
      _playbackState.fail();
      rethrow;
    }
    _recordQueuedAudio();
  }

  @visibleForTesting
  @override
  bool get hasQueuedAudio => _chapterQueueURLs.isNotEmpty || _isSegmentMode;

  @override
  void enqueueSegment(Uri uri, {String? sentenceId, int chapterIndex = 0}) {
    if (chapterIndex != _segmentChapterIndex) {
      _segmentChapterIndex = chapterIndex;
      _segmentSentenceIds.clear();
      _segmentSource = ConcatenatingAudioSource(children: []);
      _chapterSource = null;
      _chapterQueueURLs = const [];
      unawaited(_player.setAudioSource(_segmentSource!, preload: false));
    }
    if (sentenceId != null) {
      _segmentSentenceIds.add(sentenceId);
      if (_segmentSentenceIds.length == 1) {
        _activeSentenceId = sentenceId;
        _sentenceController.add(sentenceId);
      }
    }

    _segmentSource?.add(AudioSource.uri(uri));
    _recordQueuedAudio();

    if (!_isSegmentMode) {
      _isSegmentMode = true;
      _listenSegmentTransitions();
    }
  }

  void _listenSegmentTransitions() {
    _indexSub?.cancel();
    _indexSub = _player.currentIndexStream.listen((idx) {
      if (idx != null && _isSegmentMode && idx < _segmentSentenceIds.length) {
        _activeSentenceId = _segmentSentenceIds[idx];
        _sentenceController.add(_activeSentenceId);
      }
    });
  }

  Uri _resolve(String base, String urlOrPath) {
    if (urlOrPath.startsWith('http') || urlOrPath.startsWith('file:')) {
      return Uri.parse(urlOrPath);
    }
    if (urlOrPath.startsWith('/')) {
      return Uri.file(urlOrPath);
    }
    final cleanBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final cleanPath = urlOrPath.startsWith('/') ? urlOrPath : '/$urlOrPath';
    return Uri.parse('$cleanBase$cleanPath');
  }

  @override
  Future<void> play() async {
    // ignore: avoid_print
    print(
      'AudioPlayer play requested sourceCount=${_chapterQueueURLs.length} segment=$_isSegmentMode',
    );
    if (!hasQueuedAudio) {
      // ignore: avoid_print
      print('AudioPlayer play ignored: no queued audio');
      return;
    }
    final restart = phase == PlaybackPhase.completed;
    if (restart || phase == PlaybackPhase.failed) {
      await _player.pause();
      if (restart) await _player.seek(Duration.zero);
    }
    _playbackJourneyId ??= latencyObservations.begin(
      LatencyJourneyKind.progressivePlayback,
      LatencyTransition.playRequested,
    );
    _recordQueuedAudio();
    _listenForPlayableAudio();
    _listenForAudibleOutput();
    _playbackState.beginRequest(_player.playerState);
    try {
      await _player.play();
    } catch (_) {
      _playbackState.fail();
      rethrow;
    }
  }

  @override
  Future<void> pause() {
    final id = _playbackJourneyId;
    if (id != null) latencyObservations.cancel(id);
    _playbackJourneyId = null;
    return _player.pause();
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    final generation = ++_seekGeneration;
    final targetIndex = index ?? _player.currentIndex;
    if (targetIndex != null &&
        targetIndex >= 0 &&
        targetIndex < _playableMap.length) {
      final chapter = _chapters[_playableMap[targetIndex]];
      final growing = _growingChapters[chapter.index];
      if (position > Duration.zero &&
          growing != null &&
          growing.matches(_chapterQueueURLs[targetIndex])) {
        await growing.source.waitForSeek();
      }
    }
    if (generation != _seekGeneration) return;
    final previous = _seekJourneyId;
    if (previous != null) latencyObservations.cancel(previous);
    _seekJourneyId = latencyObservations.begin(
      LatencyJourneyKind.seek,
      LatencyTransition.seekRequested,
    );
    if (index != null &&
        index >= 0 &&
        index < _chapterQueueURLs.length &&
        _player.currentIndex != index) {
      await _player.seek(Duration.zero, index: index);
    }
    await _player.seek(position);
  }

  void _recordQueuedAudio() {
    final id = _playbackJourneyId;
    if (id != null) {
      latencyObservations.record(id, LatencyTransition.audioQueued);
    }
  }

  /// `ready` means the platform player can begin rendering the queued media.
  /// It deliberately precedes the first positive position tick, which is the
  /// earliest truthful boundary available to this client for audible output.
  void _listenForPlayableAudio() {
    _playabilitySub ??= _player.playerStateStream.listen((state) {
      if (!isPlayableProcessingState(state.processingState)) return;
      final id = _playbackJourneyId;
      if (id != null) {
        latencyObservations.record(id, LatencyTransition.audioPlayable);
      }
    });
  }

  @visibleForTesting
  static bool isPlayableProcessingState(ProcessingState state) =>
      state == ProcessingState.ready;

  void _listenForAudibleOutput() {
    _audibilitySub ??= _player.positionStream.listen((position) {
      if (position <= Duration.zero) return;
      final playbackId = _playbackJourneyId;
      if (playbackId != null) {
        latencyObservations.record(playbackId, LatencyTransition.audioAudible);
        latencyObservations.finish(playbackId);
        _playbackJourneyId = null;
      }
      final seekId = _seekJourneyId;
      if (seekId != null) {
        latencyObservations.record(seekId, LatencyTransition.seekTargetReached);
        latencyObservations.finish(seekId);
        _seekJourneyId = null;
      }
    });
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _player.setSpeed(speed);
  }

  @override
  void skipForward({int seconds = 15}) {
    final pos = _player.position;
    final dur = _player.duration ?? Duration.zero;
    final target = pos + Duration(seconds: seconds);
    unawaited(seek(dur > Duration.zero && target > dur ? dur : target));
  }

  @override
  void skipBackward({int seconds = 15}) {
    final pos = _player.position;
    final target = pos - Duration(seconds: seconds);
    unawaited(seek(target < Duration.zero ? Duration.zero : target));
  }

  @override
  void nextChapter() => _player.seekToNext();
  @override
  void previousChapter() => _player.seekToPrevious();

  @override
  void togglePlayPause() {
    if (isPlaying || isLoading) {
      unawaited(pause());
    } else {
      unawaited(play());
    }
  }

  @override
  void setSleepTimer({required double seconds}) {
    _sleepTimer?.cancel();
    _sleepTimerRemaining = seconds;
    _sleepController.add(_sleepTimerRemaining);
    if (seconds <= 0) return;
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sleepTimerRemaining -= 1;
      _sleepController.add(_sleepTimerRemaining);
      if (_sleepTimerRemaining <= 0) {
        _sleepTimer?.cancel();
        _sleepTimerRemaining = 0;
        _sleepController.add(0);
        _player.pause();
      }
    });
  }

  @override
  double get positionSeconds => _player.position.inMilliseconds / 1000.0;

  @override
  double get durationSeconds =>
      (_player.duration?.inMilliseconds ?? 0) / 1000.0;

  @override
  void clearSegmentState() {
    _isSegmentMode = false;
    _segmentChapterIndex = -1;
    _segmentSentenceIds.clear();
    _segmentSource = null;
    _activeSentenceId = null;
    _sentenceController.add(null);
  }

  @override
  Future<void> dispose() async {
    _seekGeneration++;
    for (final entry in _growingChapters.values) {
      entry.source.fail(StateError('Audio player disposed'));
    }
    _growingChapters.clear();
    _sleepTimer?.cancel();
    _indexSub?.cancel();
    await _playabilitySub?.cancel();
    await _audibilitySub?.cancel();
    await _sentenceController.close();
    await _sleepController.close();
    await _playbackState.dispose();
    await _player.dispose();
  }

  @override
  List<ChapterProgress> get chapters => _chapters;

  @override
  int chapterIndexForPlayerIndex(int playerIndex) {
    if (playerIndex < 0 || playerIndex >= _playableMap.length) {
      return playerIndex;
    }
    return _playableMap[playerIndex];
  }
}
