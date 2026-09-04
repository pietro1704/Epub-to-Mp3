import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import '../models/job_snapshot.dart';
import 'latency_observation.dart';

abstract class AudioPlayerInterface {
  Stream<Duration> get position;
  Stream<bool> get playing;
  bool get isPlaying;
  Stream<int?> get currentIndex;
  int? get currentIndexValue;
  String? get activeSentenceId;
  Stream<String?> get activeSentenceStream;
  double get speed;
  double get sleepTimerRemaining;
  Stream<double> get sleepTimerStream;
  double get positionSeconds;
  double get durationSeconds;
  Uint8List? coverArtData;
  List<ChapterProgress> get chapters;
  int chapterIndexForPlayerIndex(int playerIndex);

  Future<void> setQueue(List<ChapterProgress> chapters);
  void enqueueSegment(Uri uri, {String? sentenceId, int chapterIndex});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position, {int? index});
  Future<void> setSpeed(double speed);
  void skipForward({int seconds});
  void skipBackward({int seconds});
  void nextChapter();
  void previousChapter();
  void togglePlayPause();
  void setSleepTimer({required double seconds});
  void clearSegmentState();
  Future<void> dispose();
}

class AudioPlayerService implements AudioPlayerInterface {
  AudioPlayerService({String? backendBase, AudioPlayer? player})
    : _baseUrl = backendBase,
      _player = player ?? AudioPlayer();

  final AudioPlayer _player;
  final String? _baseUrl;
  List<ChapterProgress> _chapters = const [];

  @override
  Stream<Duration> get position => _player.positionStream;
  @override
  Stream<bool> get playing => _player.playingStream;
  @override
  bool get isPlaying => _player.playing;
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

  @override
  Future<void> setQueue(List<ChapterProgress> chapters) async {
    final base = _baseUrl ?? '';
    final children = <AudioSource>[];
    final map = <int>[];
    final urls = <Uri>[];
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      if (c.downloadUrl != null) {
        final url = _resolve(base, c.downloadUrl!);
        children.add(AudioSource.uri(url));
        urls.add(url);
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
    if (children.isEmpty) return;

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
    await _player.setAudioSource(_chapterSource!, preload: false);
    _recordQueuedAudio();
  }

  @override
  void enqueueSegment(Uri uri, {String? sentenceId, int chapterIndex = 0}) {
    if (chapterIndex != _segmentChapterIndex) {
      _segmentChapterIndex = chapterIndex;
      _segmentSentenceIds.clear();
      _segmentSource = ConcatenatingAudioSource(children: []);
      _chapterSource = null;
      _chapterQueueURLs = const [];
      _player.setAudioSource(_segmentSource!, preload: false);
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
    final cleanBase = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    final cleanPath = urlOrPath.startsWith('/') ? urlOrPath : '/$urlOrPath';
    return Uri.parse('$cleanBase$cleanPath');
  }

  @override
  Future<void> play() {
    _playbackJourneyId ??= latencyObservations.begin(
      LatencyJourneyKind.progressivePlayback,
      LatencyTransition.interactionRequested,
    );
    _recordQueuedAudio();
    _listenForAudibleOutput();
    return _player.play();
  }

  @override
  Future<void> pause() {
    final id = _playbackJourneyId;
    if (id != null) latencyObservations.cancel(id);
    _playbackJourneyId = null;
    return _player.pause();
  }

  @override
  Future<void> seek(Duration position, {int? index}) {
    final previous = _seekJourneyId;
    if (previous != null) latencyObservations.cancel(previous);
    _seekJourneyId = latencyObservations.begin(
      LatencyJourneyKind.seek,
      LatencyTransition.seekRequested,
    );
    return _player.seek(position, index: index);
  }

  void _recordQueuedAudio() {
    final id = _playbackJourneyId;
    if (id != null) {
      latencyObservations.record(id, LatencyTransition.audioQueued);
    }
  }

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
    _player.seek(target > dur ? dur : target);
  }

  @override
  void skipBackward({int seconds = 15}) {
    final pos = _player.position;
    final target = pos - Duration(seconds: seconds);
    _player.seek(target < Duration.zero ? Duration.zero : target);
  }

  @override
  void nextChapter() => _player.seekToNext();
  @override
  void previousChapter() => _player.seekToPrevious();

  @override
  void togglePlayPause() {
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
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
    _sleepTimer?.cancel();
    _indexSub?.cancel();
    await _audibilitySub?.cancel();
    await _sentenceController.close();
    await _sleepController.close();
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

/// Test double — pure Dart, no native plugins.
class FakeAudioPlayerService implements AudioPlayerInterface {
  @override
  String? activeSentenceId;
  @override
  Uint8List? coverArtData;

  double _speed = 1.0;
  double _sleepTimerRemaining = 0;
  bool _playing = false;
  List<ChapterProgress> _chapters = const [];
  int? _currentIndex;
  Duration _position = Duration.zero;
  final Duration _duration = Duration.zero;

  final _positionController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _indexController = StreamController<int?>.broadcast();
  final _sentenceController = StreamController<String?>.broadcast();
  final _sleepController = StreamController<double>.broadcast();

  @override
  Stream<Duration> get position => _positionController.stream;
  @override
  Stream<bool> get playing => _playingController.stream;
  @override
  bool get isPlaying => _playing;
  @override
  Stream<int?> get currentIndex => _indexController.stream;
  @override
  int? get currentIndexValue => _currentIndex;
  @override
  Stream<String?> get activeSentenceStream => _sentenceController.stream;
  @override
  Stream<double> get sleepTimerStream => _sleepController.stream;
  @override
  double get speed => _speed;
  @override
  double get sleepTimerRemaining => _sleepTimerRemaining;
  @override
  double get positionSeconds => _position.inMilliseconds / 1000.0;
  @override
  double get durationSeconds => _duration.inMilliseconds / 1000.0;
  @override
  List<ChapterProgress> get chapters => _chapters;

  @override
  Future<void> setQueue(List<ChapterProgress> chapters) async {
    _chapters = chapters;
    _currentIndex = chapters.isEmpty ? null : 0;
    _indexController.add(_currentIndex);
  }

  @override
  void enqueueSegment(Uri uri, {String? sentenceId, int chapterIndex = 0}) {
    if (sentenceId != null) {
      activeSentenceId = sentenceId;
      _sentenceController.add(sentenceId);
    }
  }

  @override
  Future<void> play() async {
    _playing = true;
    _playingController.add(true);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _playingController.add(false);
  }

  @override
  Future<void> seek(Duration position, {int? index}) async {
    _position = position;
    _positionController.add(position);
    if (index != null) {
      _currentIndex = index;
      _indexController.add(index);
    }
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed;
  }

  @override
  void skipForward({int seconds = 15}) {
    _position += Duration(seconds: seconds);
    _positionController.add(_position);
  }

  @override
  void skipBackward({int seconds = 15}) {
    final target = _position - Duration(seconds: seconds);
    _position = target < Duration.zero ? Duration.zero : target;
    _positionController.add(_position);
  }

  @override
  void nextChapter() {}
  @override
  void previousChapter() {}

  @override
  void togglePlayPause() {
    if (_playing) {
      pause();
    } else {
      play();
    }
  }

  @override
  void setSleepTimer({required double seconds}) {
    _sleepTimerRemaining = seconds;
    _sleepController.add(seconds);
  }

  @override
  int chapterIndexForPlayerIndex(int playerIndex) => playerIndex;

  @override
  void clearSegmentState() {
    activeSentenceId = null;
    _sentenceController.add(null);
  }

  @override
  Future<void> dispose() async {
    await _positionController.close();
    await _playingController.close();
    await _indexController.close();
    await _sentenceController.close();
    await _sleepController.close();
  }
}
