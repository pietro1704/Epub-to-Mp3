/// Playback intent and timing cross this seam; Rust owns eligibility thresholds.
abstract interface class ListeningSchedule {
  void moveTo(int chapterIndex);
  bool permits(int chapterIndex);
  void feedback({required int chapterIndex, required double remainingSeconds,
    required double playbackRate});
  void observeGeneration(double seconds, int textCharacters);
  void close();
}

abstract interface class ListeningScheduleFactory {
  ListeningSchedule createListeningSchedule(int initialChapterIndex);
}
