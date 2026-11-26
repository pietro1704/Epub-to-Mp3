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

/// What the reader needs from the playback session for the contents menu.
class ReaderDownloadActions {
  const ReaderDownloadActions({
    required this.downloadAll,
    required this.cancel,
    required this.retryFrom,
    required this.shareAudio,
  });
  final Future<void> Function() downloadAll;
  final Future<void> Function() cancel;
  final Future<void> Function(int chapterIndex) retryFrom;
  final Future<void> Function() shareAudio;
}

/// Bulk audio actions of the contents menu (mirrors the 16e contents "more" menu).
enum ContentsDownloadAction { downloadAll, cancel, retryFailed, shareAudio }

/// The actions that apply to [states] for a book of [chapterCount] chapters:
/// Cancel while a chapter converts (Download waits for it to end), Download
/// while some chapter has no audio, Retry when a chapter failed.
List<ContentsDownloadAction> contentsDownloadActions(
  Map<int, ChapterAudioState> states,
  int chapterCount,
) {
  final converting = states.containsValue(ChapterAudioState.converting);
  final ready = states.values.where((s) => s == ChapterAudioState.ready).length;
  return [
    if (converting) ContentsDownloadAction.cancel,
    if (!converting && ready < chapterCount) ContentsDownloadAction.downloadAll,
    if (states.containsValue(ChapterAudioState.failed)) ContentsDownloadAction.retryFailed,
    if (ready > 0) ContentsDownloadAction.shareAudio,
  ];
}

/// The lowest 0-based chapter index whose conversion failed, if any.
int? firstFailedChapter(Map<int, ChapterAudioState> states) {
  final failed = [
    for (final e in states.entries)
      if (e.value == ChapterAudioState.failed) e.key,
  ]..sort();
  return failed.isEmpty ? null : failed.first;
}
