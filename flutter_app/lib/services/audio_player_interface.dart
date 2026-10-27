import 'dart:typed_data';

import '../models/job_snapshot.dart';
import 'growing_chapter_audio_source.dart';

abstract interface class StreamingChapterPlayer {
  void registerGrowingChapter(
    int chapterIndex,
    GrowingChapterAudioSource source,
  );
  void finishGrowingChapter(int chapterIndex, String finalPath);
}

enum PlaybackPhase { idle, loading, buffering, playing, paused, completed, failed }

abstract class AudioPlayerInterface {
  PlaybackPhase get phase => isLoading ? PlaybackPhase.loading
      : isPlaying ? PlaybackPhase.playing
      : hasQueuedAudio ? PlaybackPhase.paused : PlaybackPhase.idle;
  Stream<PlaybackPhase> get phases => playing.map((_) => phase);
  Stream<Duration> get position;
  Stream<bool> get playing;
  bool get isPlaying;
  bool get isLoading;
  Stream<int?> get currentIndex;
  int? get currentIndexValue;
  String? get activeSentenceId;
  Stream<String?> get activeSentenceStream;
  double get speed;
  double get sleepTimerRemaining;
  Stream<double> get sleepTimerStream;
  double get positionSeconds;
  double get durationSeconds;
  Uint8List? get coverArtData;
  set coverArtData(Uint8List? value);
  List<ChapterProgress> get chapters;
  bool get hasQueuedAudio;
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
