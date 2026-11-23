import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:just_audio/just_audio.dart';

import '../../models/job_snapshot.dart';
import '../latency_observation.dart';
import 'growing_chapter_audio_source.dart';

import 'audio_player_interface.dart';
import 'audio_playback_state.dart';

export 'audio_player_interface.dart';

part 'audio_player_navigation.dart';

class _GrowingChapterEntry {
  _GrowingChapterEntry(this.source);
  final GrowingChapterAudioSource source;
  String? finalPath;
  Uri get identity => Uri(scheme: 'growing', path: source.requestId);
  bool matches(Uri uri) =>
      uri == identity || finalPath != null && uri == Uri.file(finalPath!);
}

class AudioPlayerService extends AudioPlayerInterface
    with _AudioPlayerNavigation
    implements StreamingChapterPlayer {
  AudioPlayerService({AudioPlayer? player})
    : _player = player ?? AudioPlayer() {
    _playbackState = AudioPlaybackState(_player);
  }

  @override
  final AudioPlayer _player;
  late final AudioPlaybackState _playbackState;
  @override
  PlaybackPhase get phase => _playbackState.phase;
  @override
  Stream<PlaybackPhase> get phases => _playbackState.changes;
  List<ChapterProgress> _chapters = const [];

  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<bool> get playing =>
      phases.map((phase) => phase == PlaybackPhase.playing);
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
  @override
  Uri? get currentAudioUri {
    final source = _player.sequenceState.currentSource;
    if (source is UriAudioSource) return source.uri;
    final index = currentIndexValue;
    if (index == null) return null;
    final queueIndex = chapterIndexForPlayerIndex(index);
    if (queueIndex < 0 || queueIndex >= chapters.length) return null;
    final path = _growingChapters[chapters[queueIndex].index]?.finalPath;
    return path == null ? null : Uri.file(path);
  }

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

  Future<void> _segmentUpdates = Future<void>.value();
  int _segmentGeneration = 0;
  List<Uri> _chapterQueueURLs = const [];
  Future<void> _chapterQueueUpdates = Future.value();
  @override
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
  Future<void> setQueue(List<ChapterProgress> chapters) =>
      _updateChapterQueue(() => _setChapterQueue(chapters));

  Future<void> _updateChapterQueue(Future<void> Function() update) {
    final pending = _chapterQueueUpdates.then((_) => update());
    _chapterQueueUpdates = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> _setChapterQueue(List<ChapterProgress> chapters) async {
    if (chapters.isEmpty) {
      // An empty queue is how callers clear the player (switching books,
      // removing derived data); it is not a failed request.
      await _clearChapterQueue();
      return;
    }
    _playbackState.beginRequest(_player.playerState);
    debugPrint('AudioPlayer setQueue chapters=${chapters.length}');
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
        final url = _resolveLocal(c.downloadUrl!);
        if (url == null) continue;
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
        !_isSegmentMode &&
        _chapterQueueURLs.isNotEmpty &&
        urls.length >= _chapterQueueURLs.length &&
        _chapterQueueURLs.asMap().entries.every(
          (entry) => urls[entry.key] == entry.value,
        );
    _chapters = chapters;
    _playableMap = map;
    debugPrint('AudioPlayer resolvedSources=${urls.length} urls=$urls');
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
        await _player.addAudioSource(children[index]);
      }
      _chapterQueueURLs = urls;
      return;
    }

    _isSegmentMode = false;
    _segmentGeneration++;
    await _segmentUpdates;
    _chapterQueueURLs = urls;
    try {
      await _player.setAudioSources(children, preload: false);
    } catch (_) {
      _playbackState.fail();
      rethrow;
    }
    _recordQueuedAudio();
  }

  Future<void> _clearChapterQueue() async {
    _isSegmentMode = false;
    _segmentGeneration++;
    _chapters = const [];
    _playableMap = const [];
    _chapterQueueURLs = const [];
    await _segmentUpdates;
    await _player.stop();
    await _player.clearAudioSources();
    _playbackState.beginRequest(_player.playerState);
  }

  @visibleForTesting
  @override
  bool get hasQueuedAudio => _chapterQueueURLs.isNotEmpty || _isSegmentMode;

  @override
  void enqueueSegment(Uri uri, {String? sentenceId, int chapterIndex = 0}) {
    final replacesChapter = chapterIndex != _segmentChapterIndex;
    if (replacesChapter) {
      _segmentGeneration++;
      _segmentChapterIndex = chapterIndex;
      _segmentSentenceIds.clear();

      _chapterQueueURLs = const [];
    }
    if (sentenceId != null) {
      _segmentSentenceIds.add(sentenceId);
      if (_segmentSentenceIds.length == 1) {
        _activeSentenceId = sentenceId;
        _sentenceController.add(sentenceId);
      }
    }

    final generation = _segmentGeneration;
    _segmentUpdates = _segmentUpdates
        .then((_) async {
          if (generation != _segmentGeneration) return;
          if (replacesChapter) {
            await _player.setAudioSources([
              AudioSource.uri(uri),
            ], preload: false);
          } else {
            await _player.addAudioSource(AudioSource.uri(uri));
          }
        })
        .catchError((Object error) {
          if (generation == _segmentGeneration) _playbackState.fail();
        });
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

  /// Chapter audio is local: `file:` URIs or absolute paths. Relative paths
  /// and plain `http` URLs were only playable through the removed remote
  /// backend base URL, so they are skipped exactly as when no base was set.
  Uri? _resolveLocal(String urlOrPath) {
    if (urlOrPath.startsWith('/')) return Uri.file(urlOrPath);
    if (!urlOrPath.startsWith('http') && !urlOrPath.startsWith('file:')) {
      return null;
    }
    final url = Uri.parse(urlOrPath);
    return url.scheme == 'http' ? null : url;
  }

  @override
  Future<void> play() async {
    await _segmentUpdates;
    debugPrint(
      'AudioPlayer play requested sourceCount=${_chapterQueueURLs.length} segment=$_isSegmentMode',
    );
    if (!hasQueuedAudio) {
      debugPrint('AudioPlayer play ignored: no queued audio');
      return;
    }
    final restart = phase == PlaybackPhase.completed;
    if (restart || phase == PlaybackPhase.failed) {
      if (restart) {
        // Reopen the decoder: some desktop backends retain completed after seek.
        await _player.stop();
        await _player.seek(Duration.zero);
      } else {
        await _player.pause();
      }
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
    if (position > Duration.zero && targetIndex != null) {
      await _waitForChapterSeek(targetIndex);
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
      await _selectQueuedChapter(index);
      if (position == Duration.zero || generation != _seekGeneration) return;
      if (_player.processingState != ProcessingState.idle) {
        await _readyChapterEvent(index);
      }
    }
    if (generation != _seekGeneration) return;
    await _player.seek(position);
  }

  @override
  Future<void> _waitForChapterSeek(int playerIndex) async {
    if (playerIndex < 0 || playerIndex >= _player.sequence.length) return;
    final source = _player.sequence[playerIndex];
    if (source is! GrowingChapterAudioSource) return;

    final generation = _seekGeneration;
    await source.waitForSeek();
    final path = source.completedPath;
    if (path == null) return;

    // A desktop decoder that opened the live response may keep its original
    // duration and seekability. Load the finished file for subsequent seeks.
    await _updateChapterQueue(() async {
      if (generation != _seekGeneration) return;
      final sources = List<AudioSource>.of(_player.audioSources);
      final index = sources.indexOf(source);
      if (index < 0) return;
      sources[index] = AudioSource.uri(Uri.file(path));
      await _player.setAudioSources(
        sources,
        initialIndex: _player.currentIndex,
        initialPosition: _player.position,
      );
    });
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
    _segmentGeneration++;
    _activeSentenceId = null;
    _sentenceController.add(null);
  }

  @override
  Future<void> dispose() async {
    _seekGeneration++;
    _segmentGeneration++;
    await _segmentUpdates;
    await _chapterQueueUpdates;
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
