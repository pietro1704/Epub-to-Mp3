part of 'audio_player_service.dart';

mixin _AudioPlayerNavigation on AudioPlayerInterface {
  static const _chapterLoadTimeout = Duration(seconds: 5);
  AudioPlayer get _player;
  int get _seekGeneration;
  set _seekGeneration(int value);
  Future<void> _waitForChapterSeek(int playerIndex);

  @override
  void skipForward({int? seconds}) =>
      _startNavigation(Duration(seconds: seconds ?? seekForwardSeconds));

  @override
  void skipBackward({int? seconds}) =>
      _startNavigation(Duration(seconds: -(seconds ?? seekBackwardSeconds)));

  @override
  void nextChapter() => _startNavigation(null, direction: 1);

  @override
  void previousChapter() => _startNavigation(null, direction: -1);

  void _startNavigation(Duration? offset, {int? direction}) {
    final generation = ++_seekGeneration;
    final bookId = currentBookId;
    bool isCurrent() =>
        generation == _seekGeneration && bookId == currentBookId;
    unawaited(
      _navigate(offset, direction, isCurrent).catchError((Object error) {
        if (isCurrent()) debugPrint('Chapter navigation failed: $error');
      }),
    );
  }

  int? _sourceAt(int? playerIndex) {
    if (playerIndex == null) return null;
    final index = chapterIndexForPlayerIndex(playerIndex);
    return index >= 0 && index < chapters.length ? chapters[index].index : null;
  }

  int? _queuedIndex(int source) {
    for (var index = 0; index < _player.sequence.length; index++) {
      if (_sourceAt(index) == source) return index;
    }
    return null;
  }

  Future<void> _selectQueuedChapter(int index) async {
    // An indexed seek with a concrete offset can race the decoder opening
    // the new item. Select its default position before seeking within it.
    await _player.seek(null, index: index);
    await _player.currentIndexStream
        .firstWhere((current) => current == index)
        .timeout(_chapterLoadTimeout);
  }

  Future<PlaybackEvent> _readyChapterEvent(int index) => _player
      .playbackEventStream
      .firstWhere(
        (event) =>
            event.currentIndex == index &&
            event.processingState == ProcessingState.ready &&
            (event.duration ?? Duration.zero) > Duration.zero,
      )
      .timeout(_chapterLoadTimeout);

  Future<void> _navigate(
    Duration? offset,
    int? direction,
    bool Function() isCurrent,
  ) async {
    final firstIndex = _player.currentIndex;
    final firstSource = _sourceAt(firstIndex);
    final sourceIndices = sourceChapterIndices.contains(firstSource)
        ? sourceChapterIndices
        : [
            for (var index = 0; index < _player.sequence.length; index++)
              if (_sourceAt(index) case final int source) source,
          ];
    if (firstIndex == null || firstSource == null) {
      if (offset != null) {
        final target = _player.position + offset;
        final end = _player.duration;
        await seek(
          target < Duration.zero
              ? Duration.zero
              : end != null && target > end
              ? end
              : target,
        );
      } else if (direction == 1) {
        await _player.seekToNext();
      } else {
        await _player.seekToPrevious();
      }
      return;
    }

    var sourceOffset = sourceIndices.indexOf(firstSource);
    if (sourceOffset < 0) return;
    final wasPlaying = isPlaying || (isLoading && _player.playing);
    var pausedForNavigation = false;
    var playerIndex = firstIndex;
    var target = offset == null ? Duration.zero : _player.position + offset;
    final step = direction ?? (target < Duration.zero ? -1 : 1);
    try {
      while (isCurrent()) {
        if (offset != null) {
          await _waitForChapterSeek(playerIndex);
          if (!isCurrent()) return;
        }
        final measured = _player.duration;
        final duration = measured != null && measured > Duration.zero
            ? measured
            : null;
        final next = sourceOffset + step;
        if (offset != null &&
            target >= Duration.zero &&
            (duration == null || target < duration)) {
          await _player.seek(target);
          return;
        }
        if (next < 0 || next >= sourceIndices.length) {
          if (offset != null) {
            await _player.seek(
              target < Duration.zero ? Duration.zero : duration ?? target,
            );
          }
          return;
        }
        if (wasPlaying && !pausedForNavigation) {
          await _player.pause();
          pausedForNavigation = true;
          if (!isCurrent()) return;
        }

        final source = sourceIndices[next];
        var nextIndex = _queuedIndex(source);
        if (nextIndex == null) {
          if (await onPrepareSourceChapter?.call(source) != true ||
              !isCurrent()) {
            return;
          }
          nextIndex = _queuedIndex(source);
          if (nextIndex == null) return;
        }
        if (offset != null) {
          await _waitForChapterSeek(nextIndex);
          if (!isCurrent()) return;
        }
        await _selectQueuedChapter(nextIndex);
        if (!isCurrent() || _sourceAt(_player.currentIndex) != source) return;
        if (offset == null) return;

        playerIndex = nextIndex;
        sourceOffset = next;
        final nextDuration = await _readyChapterEvent(nextIndex);
        if (!isCurrent()) return;
        if (step > 0) {
          target -= duration!;
        } else {
          target += nextDuration.duration!;
        }
      }
    } finally {
      if (pausedForNavigation && isCurrent()) {
        unawaited(
          play().catchError((Object error) {
            debugPrint(
              'Playback could not resume after chapter navigation: $error',
            );
          }),
        );
      }
    }
  }
}
