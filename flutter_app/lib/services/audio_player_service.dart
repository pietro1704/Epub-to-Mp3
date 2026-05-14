import 'dart:async';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

import '../models/job_snapshot.dart';

class AudioPlayerService {
  AudioPlayerService({String? backendBase}) : _baseUrl = backendBase;

  final AudioPlayer _player = AudioPlayer();
  final String? _baseUrl;
  List<ChapterProgress> _chapters = const [];

  Stream<Duration> get position => _player.positionStream;
  Stream<bool> get playing => _player.playingStream;
  Stream<int?> get currentIndex => _player.currentIndexStream;
  AudioPlayer get raw => _player;

  // Segment mode — sentence-level tracking
  bool _isSegmentMode = false;
  int _segmentChapterIndex = -1;
  // ignore: unused_field
  double _segmentCumulativeBase = 0;
  final List<String> _segmentSentenceIds = [];
  int _segmentPlayedCount = 0;
  String? _activeSentenceId;
  StreamSubscription<int?>? _indexSub;

  String? get activeSentenceId => _activeSentenceId;

  final _sentenceController = StreamController<String?>.broadcast();
  Stream<String?> get activeSentenceStream => _sentenceController.stream;

  // Cover art for notification/lock screen
  Uint8List? coverArtData;

  // Sleep timer
  Timer? _sleepTimer;
  double _sleepTimerRemaining = 0;
  double get sleepTimerRemaining => _sleepTimerRemaining;

  final _sleepController = StreamController<double>.broadcast();
  Stream<double> get sleepTimerStream => _sleepController.stream;

  // Playback speed
  double _speed = 1.0;
  double get speed => _speed;

  Future<void> setQueue(List<ChapterProgress> chapters) async {
    _chapters = chapters;
    final base = _baseUrl ?? '';
    final children = <AudioSource>[
      for (final c in chapters)
        if (c.downloadUrl != null)
          AudioSource.uri(_resolve(base, c.downloadUrl!)),
    ];
    if (children.isEmpty) return;
    _isSegmentMode = false;
    await _player.setAudioSource(
      ConcatenatingAudioSource(children: children),
      preload: false,
    );
  }

  void enqueueSegment(Uri uri, {String? sentenceId, int chapterIndex = 0}) {
    if (chapterIndex != _segmentChapterIndex) {
      _segmentChapterIndex = chapterIndex;
      _segmentCumulativeBase = 0;
      _segmentSentenceIds.clear();
      _segmentPlayedCount = 0;
    }
    if (sentenceId != null) {
      _segmentSentenceIds.add(sentenceId);
      if (_segmentSentenceIds.length == 1) {
        _activeSentenceId = sentenceId;
        _sentenceController.add(sentenceId);
      }
    }

    if (!_isSegmentMode) {
      _isSegmentMode = true;
      _listenSegmentTransitions();
    }

    final source = ConcatenatingAudioSource(children: [
      AudioSource.uri(uri),
    ]);
    _player.setAudioSource(source, preload: true);
  }

  void _listenSegmentTransitions() {
    _indexSub?.cancel();
    _indexSub = _player.currentIndexStream.listen((idx) {
      if (idx != null && _isSegmentMode) {
        final duration = _player.duration;
        if (duration != null) {
          _segmentCumulativeBase += duration.inMilliseconds / 1000.0;
        }
        _segmentPlayedCount++;
        if (_segmentPlayedCount < _segmentSentenceIds.length) {
          _activeSentenceId = _segmentSentenceIds[_segmentPlayedCount];
          _sentenceController.add(_activeSentenceId);
        }
      }
    });
  }

  Uri _resolve(String base, String urlOrPath) {
    if (urlOrPath.startsWith('http')) return Uri.parse(urlOrPath);
    final cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanPath = urlOrPath.startsWith('/') ? urlOrPath : '/$urlOrPath';
    return Uri.parse('$cleanBase$cleanPath');
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();

  Future<void> seek(Duration position, {int? index}) =>
      _player.seek(position, index: index);

  Future<void> setSpeed(double speed) async {
    _speed = speed;
    await _player.setSpeed(speed);
  }

  void skipForward({int seconds = 15}) {
    final pos = _player.position;
    final dur = _player.duration ?? Duration.zero;
    final target = pos + Duration(seconds: seconds);
    _player.seek(target > dur ? dur : target);
  }

  void skipBackward({int seconds = 15}) {
    final pos = _player.position;
    final target = pos - Duration(seconds: seconds);
    _player.seek(target < Duration.zero ? Duration.zero : target);
  }

  void nextChapter() => _player.seekToNext();
  void previousChapter() => _player.seekToPrevious();

  void togglePlayPause() {
    if (_player.playing) {
      _player.pause();
    } else {
      _player.play();
    }
  }

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

  double get positionSeconds =>
      _player.position.inMilliseconds / 1000.0;

  double get durationSeconds =>
      (_player.duration?.inMilliseconds ?? 0) / 1000.0;

  void clearSegmentState() {
    _isSegmentMode = false;
    _segmentChapterIndex = -1;
    _segmentCumulativeBase = 0;
    _segmentSentenceIds.clear();
    _segmentPlayedCount = 0;
    _activeSentenceId = null;
    _sentenceController.add(null);
  }

  Future<void> dispose() async {
    _sleepTimer?.cancel();
    _indexSub?.cancel();
    await _sentenceController.close();
    await _sleepController.close();
    await _player.dispose();
  }

  List<ChapterProgress> get chapters => _chapters;
}
