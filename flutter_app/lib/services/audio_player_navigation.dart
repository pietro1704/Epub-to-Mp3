part of 'audio_player_service.dart';

mixin _AudioPlayerNavigation on AudioPlayerInterface {
  AudioPlayer get _player;
  @override
  void skipForward({int? seconds}) {
    seconds ??= seekForwardSeconds;
    final pos = _player.position;
    final dur = _player.duration ?? Duration.zero;
    final target = pos + Duration(seconds: seconds);
    if (dur > Duration.zero && target >= dur && _player.hasNext) {
      nextChapter();
    } else {
      unawaited(seek(dur > Duration.zero && target > dur ? dur : target));
    }
  }

  @override
  void skipBackward({int? seconds}) {
    seconds ??= seekBackwardSeconds;
    final pos = _player.position;
    final target = pos - Duration(seconds: seconds);
    unawaited(seek(target < Duration.zero ? Duration.zero : target));
  }

  @override
  void nextChapter() => _navigateChapter(true);
  void _navigateChapter(bool forward) {
    final queueIndex = currentIndexValue == null
        ? -1
        : chapterIndexForPlayerIndex(currentIndexValue!);
    final chapter = queueIndex >= 0 && queueIndex < chapters.length
        ? chapters[queueIndex].index
        : null;
    final sourceIndex = chapter == null
        ? -1
        : sourceChapterIndices.indexOf(chapter);
    final target = sourceIndex + (forward ? 1 : -1);
    if (sourceIndex >= 0 &&
        target >= 0 &&
        target < sourceChapterIndices.length &&
        onRequestSourceChapter != null) {
      unawaited(onRequestSourceChapter!(sourceChapterIndices[target]));
    } else if (forward) {
      _player.seekToNext();
    } else {
      _player.seekToPrevious();
    }
  }

  @override
  void previousChapter() => _navigateChapter(false);
}
