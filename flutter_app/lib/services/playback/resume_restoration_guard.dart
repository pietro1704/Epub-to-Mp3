import 'resume_position_router.dart';

/// Gates the "restore last position" jump that
/// `book_open_screen` performs when the saved chapter eventually
/// lands in the playable queue.
///
/// Pre-slice-32 the screen called `_restoreResumePosition` as soon
/// as the first chapter batch arrived from the SSE stream. The
/// router returned `null` because the saved chapter (often the last
/// chapter the user listened to) had not been converted yet — and
/// the restore was silently dropped. When the saved chapter finally
/// arrived in a later batch, nothing tried again, so the user lost
/// their resume point on every reopen of a fresh conversion.
///
/// This guard converts that one-shot call into a retry-until-ready
/// pattern: each new chapter batch hands the guard a fresh
/// `ResumePositionRouter`, and the guard returns the queue index
/// only when the saved chapter is finally resolvable. After the
/// first successful resolution the guard latches — subsequent calls
/// return `null` so we never jump the player backwards if more
/// chapters arrive after the user has started playing.
class ResumeRestorationGuard {
  bool _restored = false;
  bool get hasRestored => _restored;

  int? targetForSavedValue(int savedValue, ResumePositionRouter router) {
    if (_restored) return null;
    final idx = router.queueIndexForSavedValue(savedValue);
    if (idx == null) return null;
    _restored = true;
    return idx;
  }
}
