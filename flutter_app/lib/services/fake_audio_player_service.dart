import 'dart:async';
import 'dart:typed_data';

import '../models/job_snapshot.dart';
import 'audio_player_interface.dart';

/// Test double — pure Dart, no native plugins.
class FakeAudioPlayerService extends AudioPlayerInterface {
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
  bool get isLoading => false;
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
  bool get hasQueuedAudio => _chapters.isNotEmpty;

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
  void nextChapter() {
    final current = _currentIndex;
    if (current == null || current + 1 >= _chapters.length) return;
    _currentIndex = current + 1;
    _indexController.add(_currentIndex);
  }

  @override
  void previousChapter() {
    final current = _currentIndex;
    if (current == null || current <= 0) return;
    _currentIndex = current - 1;
    _indexController.add(_currentIndex);
  }

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
