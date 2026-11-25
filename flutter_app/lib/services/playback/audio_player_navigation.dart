part of 'audio_player_service.dart';

mixin _AudioPlayerNavigation on AudioPlayerInterface {
  static const _chapterLoadTimeout = Duration(seconds: 5);
  AudioPlayer get _player;
  int get _seekGeneration;
  set _seekGeneration(int value);
  Future<void> _waitForChapterSeek(int playerIndex);

  /// The chapter's audio is still being synthesized, so it cannot be sought.
  bool _isChapterStillGrowing(int sourceChapter);

  /// The queued item is a live stream whose synthesis was cancelled: opening it only fails.
  bool _isQueuedStreamDead(int playerIndex);

  /// Repeated skip taps accumulate into one navigation instead of replacing
  /// each other; it runs once the taps pause.
  static const _skipAccumulationWindow = Duration(milliseconds: 250);
  Duration _pendingSkip = Duration.zero;
  Timer? _pendingSkipTimer;

  void _accumulateSkip(Duration offset) {
    _pendingSkip += offset;
    _pendingSkipTimer?.cancel();
    _pendingSkipTimer = Timer(_skipAccumulationWindow, () {
      final total = _pendingSkip;
      _pendingSkip = Duration.zero;
      _pendingSkipTimer = null;
      if (total != Duration.zero) _startNavigation(total);
    });
  }

  void _dropPendingSkip() {
    _pendingSkipTimer?.cancel();
    _pendingSkipTimer = null;
    _pendingSkip = Duration.zero;
  }

  @override
  void skipForward({int? seconds}) =>
      _accumulateSkip(Duration(seconds: seconds ?? seekForwardSeconds));

  @override
  void skipBackward({int? seconds}) =>
      _accumulateSkip(Duration(seconds: -(seconds ?? seekBackwardSeconds)));

  @override
  void nextChapter() {
    _dropPendingSkip();
    _startNavigation(null, direction: 1);
  }

  @override
  void previousChapter() {
    _dropPendingSkip();
    _startNavigation(null, direction: -1);
  }

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
      if (_sourceAt(index) == source && !_isQueuedStreamDead(index)) {
        return index;
      }
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
          // A chapter that is still being synthesized cannot be sought: restart
          // synthesis at the estimated text position instead of waiting for the
          // whole chapter to finish ("loading forever").
          final skipOutside = onSkipOutsideCache;
          final playing = _sourceAt(playerIndex);
          if (playing != null &&
              _isChapterStillGrowing(playing) &&
              skipOutside != null &&
              target >= Duration.zero &&
              await skipOutside(playing, target)) {
            return;
          }
          if (!isCurrent()) return;
          // Going back past this chapter's start never needs its audio.
          if (target >= Duration.zero) {
            await _waitForChapterSeek(playerIndex);
            if (!isCurrent()) return;
          }
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
          if (await onPrepareSourceChapter?.call(
                    source,
                    seekable: offset != null,
                  ) !=
                  true ||
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
