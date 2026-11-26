import '../services/conversion/local_conversion_record.dart';

/// What the contents list shows next to a chapter about its narration audio
/// (mirrors the 16e per-chapter audio state in the contents screen).
enum ChapterAudioState { ready, converting, failed }

/// The audio state per 0-based chapter index from the book's local
/// conversion [job]. Chapters that have not started, or finished without an
/// output file, have no entry.
Map<int, ChapterAudioState> chapterAudioStates(LocalConversionJob? job) {
  if (job == null) return const {};
  final states = <int, ChapterAudioState>{};
  for (final chapter in job.chapters) {
    final state = switch (chapter.status) {
      'completed' when (chapter.outputPath ?? '').isNotEmpty => ChapterAudioState.ready,
      'failed' => ChapterAudioState.failed,
      'running' => ChapterAudioState.converting,
      _ => null,
    };
    if (state != null) states[chapter.index] = state;
  }
  return states;
}
