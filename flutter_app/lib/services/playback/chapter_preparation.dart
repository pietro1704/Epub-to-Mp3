import 'dart:async';

import '../../models/job_snapshot.dart';

/// A request to bring one source chapter into the playback queue (the player asks for it when
/// a skip or a next/previous button reaches a chapter that is not synthesized yet).
///
/// The request resolves once the chapter is playable. A caller that will SEEK inside the chapter
/// ([seekable]) needs the finished audio, so its growing stream is withheld until it completes. A
/// plain next/previous (car head unit, headphones, lock screen) only starts listening: the chapter
/// is playable as soon as its stream is queued, while it is still being synthesized. Waiting for
/// the whole chapter there paused playback for as long as the synthesis took.
class ChapterPreparation {
  int? _target;
  bool _seekable = true;
  Completer<bool>? _ready;

  int? get target => _target;

  /// Starts preparing [target]; a previous unfinished request resolves to false.
  Future<bool> start(int target, {required bool seekable}) {
    finish(false);
    final ready = Completer<bool>();
    _target = target;
    _seekable = seekable;
    _ready = ready;
    return ready.future;
  }

  /// Whether the chapter's growing stream must NOT be queued yet.
  bool holdsStreaming(int chapter) => _target == chapter && _seekable;

  /// The playable queue changed: resolves the request when its chapter can be played.
  void queueUpdated(Iterable<ChapterProgress> playable) {
    final target = _target;
    if (target != null &&
        playable.any(
          (chapter) =>
              chapter.index == target &&
              chapter.downloadUrl != null &&
              (chapter.status == 'completed' ||
                  (!_seekable && chapter.status == 'running')),
        )) {
      finish(true);
    }
  }

  void finish(bool ready) {
    final completer = _ready;
    _target = null;
    _ready = null;
    if (completer != null && !completer.isCompleted) completer.complete(ready);
  }
}
