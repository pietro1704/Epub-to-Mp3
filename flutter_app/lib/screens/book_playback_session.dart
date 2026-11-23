part of 'book_open_screen.dart';

mixin BookPlaybackSession on ConsumerState<BookOpenScreen>, BookContentSession {
  // Local conversion state
  bool _isConverting = false;
  final List<ChapterProgress> _playableChapters = [];
  LocalConversionJob? _localJob;
  ResumeRestorationGuard _resumeGuard = ResumeRestorationGuard();
  StreamSubscription<int?>? _chapterIndexSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _resumeSaveTimer;
  Future<void> Function()? _playbackRequest;
  StreamController<int> _playbackWindowChanges =
      StreamController<int>.broadcast();
  Future<void>? _localPlaybackConversion;
  int _localConversionGeneration = 0;
  int? _requestedPlaybackChapterIndex;
  ReaderListeningPosition? _readerListeningPosition;
  int? _readerStartGeneration;
  final PlaybackFirstResourcePolicy _resourcePolicy =
      PlaybackFirstResourcePolicy();
  StreamSubscription<dynamic>? _platformVoiceSubscription;
  final _platformVoiceSession = PlatformVoiceNoticeSession();
  final _playbackStartup = ReaderPlaybackStartup();
  RustPlaybackConversionService? _activeConversionService;
  (int, Completer<bool>)? _chapterPreparation;

  void _showConversionError(Object error) {
    if (!mounted) return;
    final detail = error.toString();
    final l10n = AppLocalizations.of(context)!;
    final message = isBookLanguageUncertain(error)
        ? '${l10n.conversionFailed}: ${l10n.bookLanguageUncertain}'
        : detail.contains('NO_MODEL') ||
            detail.contains('ENGINE_UNAVAILABLE') ||
            detail.contains('No TTS engine')
        ? '${l10n.conversionFailed}: ${l10n.settingsTitle}'
        : '${l10n.conversionFailed}: $detail';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startConversion() async {
    debugPrint(
      'BookOpenScreen: start conversion requested for ${widget.bookId}',
    );
    final ft = _fulltext;
    if (ft == null || ft.chapters.isEmpty) return;
    if (mounted) setState(() => _isConverting = true);

    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows)) {
      final player = ref.read(globalAudioPlayerProvider);
      final savedChapter = ref
          .read(resumeStoreProvider)
          .loadBookPosition(widget.bookId)
          ?.chapter;
      final readerPosition =
          ref.read(embeddedConverterProvider) is PositionedChapterConverter
          ? _readerListeningPosition
          : null;
      await _startLocalConversion(
        readerPosition: readerPosition,
        playbackChapterIndex:
            readerPosition?.chapterIndex ??
            (_playableChapters.isEmpty || player.currentIndexValue == null
                ? savedChapter ?? 0
                : _sourceChapterIndexForPlayerIndex(
                    player,
                    player.currentIndexValue!,
                  )),
      );
      return;
    }
    // Platforms without a registered Rust adapter cannot convert locally.
    _showConversionError(
      EmbeddedConverterUnavailable(
        'No local Rust audio adapter is registered for this platform.',
      ),
    );
    if (mounted) setState(() => _isConverting = false);
  }

  /// A new narration model applies immediately while listening: a fresh job
  /// starts at the reader's current position and captures the saved model.
  /// Idle readers only persist the choice; the next listen uses it.
  Future<void> _narrationModelChanged(TtsSelection selection) async {
    final position = narrationSwitchRestartPosition(
      position: _readerListeningPosition,
      listening: ref.read(globalAudioPlayerProvider).isPlaying || _isConverting,
      supportsPositionedStart:
          ref.read(embeddedConverterProvider) is PositionedChapterConverter,
    );
    if (!mounted || position == null) return;
    await _startLocalConversion(
      readerPosition: position,
      playbackChapterIndex: position.chapterIndex,
    );
  }

  Future<void> _startLocalConversion({
    required int playbackChapterIndex,
    ReaderListeningPosition? readerPosition,
    bool prepareOnly = false,
  }) async {
    if (!prepareOnly) _finishChapterPreparation(false);
    final existing = _localPlaybackConversion;
    if (existing != null && readerPosition == null) {
      if (!prepareOnly) {
        _playbackStartup.request(
          _localConversionGeneration,
          playbackChapterIndex,
        );
      }
      _publishPlaybackWindow(playbackChapterIndex);
      return existing;
    }
    if (existing != null) {
      ++_localConversionGeneration;
      await _activeConversionService?.cancel();
      await existing;
      if (!mounted) return;
      _localPlaybackConversion = null;
    }
    _publishPlaybackWindow(playbackChapterIndex);
    final generation = ++_localConversionGeneration;
    _readerStartGeneration = readerPosition == null ? null : generation;
    if (readerPosition != null) {
      _playableChapters.clear();
      _resumeGuard = ResumeRestorationGuard();
    }
    if (!prepareOnly) _playbackStartup.request(generation, playbackChapterIndex);
    final future =
        _runLocalPlaybackConversion(
          playbackChapterIndex: playbackChapterIndex,
          generation: generation,
          readerPosition: readerPosition,
        ).whenComplete(() {
          if (generation == _localConversionGeneration) {
            _localPlaybackConversion = null;
          }
        });
    _localPlaybackConversion = future;
    return future;
  }

  bool _isCurrentConversion(int generation) =>
      mounted && generation == _localConversionGeneration;

  void _scheduleRequestedPlayback(AudioPlayerInterface player, int generation) {
    if (!_isCurrentConversion(generation)) return;
    unawaited(
      _playbackStartup
          .startWhenReady(
            generation,
            _playableChapters.map((chapter) => chapter.index).toList(),
            (queueIndex) async {
              if (_readerStartGeneration != generation) {
                await _restoreResumePosition(player);
              }
              if (!_isCurrentConversion(generation) ||
                  !_playbackStartup.accepts(generation)) {
                return;
              }
              if (!_resumeGuard.hasRestored) {
                await player.seek(Duration.zero, index: queueIndex);
              }
              if (!_isCurrentConversion(generation) ||
                  !_playbackStartup.accepts(generation)) {
                return;
              }
              _startResumeListener(player);
              unawaited(
                player.play().catchError((Object error) {
                  if (_isCurrentConversion(generation)) {
                    _showConversionError(error);
                  }
                }),
              );
              ref.read(playbackCoordinatorProvider).firstAudioReady();
              if (mounted) setState(() => _isConverting = false);
            },
          )
          .catchError((Object error) {
            if (_isCurrentConversion(generation)) _showConversionError(error);
          }),
    );
  }

  void _setCoverOnPlayer(AudioPlayerInterface player) {
    player.currentBookId = widget.bookId;
    final source = _fulltext?.chapters ?? const [];
    player.sourceChapterIndices = [
      for (var index = 0; index < source.length; index++)
        if (source[index].text.trim().isNotEmpty) index,
    ];
    player.onPrepareSourceChapter = (target) {
      if (!mounted || player.currentBookId != widget.bookId) {
        return Future.value(false);
      }
      _finishChapterPreparation(false);
      _playbackStartup.invalidate();
      final ready = Completer<bool>();
      _chapterPreparation = (target, ready);
      unawaited(
        _startLocalConversion(playbackChapterIndex: target, prepareOnly: true)
            .whenComplete(() {
              if (identical(_chapterPreparation?.$2, ready)) {
                _finishChapterPreparation(false);
              }
            }),
      );
      return ready.future;
    };
    final library = ref.read(libraryStoreProvider);
    final idx = library.books.indexWhere((b) => b.id == widget.bookId);
    if (idx < 0) return;
    final book = library.books[idx];
    if (book.coverBase64 != null && player.coverArtData == null) {
      try {
        player.coverArtData = base64Decode(book.coverBase64!);
      } catch (error) {
        debugPrint('BookOpenScreen: ignoring unreadable cover art: $error');
      }
    }
  }

  void _chapterQueueUpdated() {
    final target = _chapterPreparation?.$1;
    if (target != null &&
        _playableChapters.any(
          (chapter) =>
              chapter.index == target &&
              chapter.status == 'completed' &&
              chapter.downloadUrl != null,
        )) {
      _finishChapterPreparation(true);
    }
  }

  void _finishChapterPreparation(bool ready) {
    final preparation = _chapterPreparation;
    _chapterPreparation = null;
    preparation?.$2.complete(ready);
  }

  void _startResumeListener(AudioPlayerInterface player) {
    _positionSub?.cancel();
    _positionSub = null;
    _chapterIndexSub?.cancel();
    _chapterIndexSub = player.currentIndex
        .where((index) => index != null)
        .map((index) => _sourceChapterIndexForPlayerIndex(player, index!))
        .distinct()
        .listen((chapter) {
          // The decoder can report its old item while we append a new one.
          // Keep the explicitly requested conversion inside the window.
          if (_chapterPreparation == null) _publishPlaybackWindow(chapter);
        });
    _positionSub = player.position.listen((_) {
      final index = player.currentIndexValue;
      if (index == null || player.durationSeconds <= 0) return;
      final chapter = _sourceChapterIndexForPlayerIndex(player, index);
      if (!_playableChapters.any(
        (entry) => entry.index == chapter && entry.status == 'completed',
      )) {
        return;
      }
      _activeConversionService?.playbackFeedback(
        chapterIndex: chapter,
        remainingSeconds: (player.durationSeconds - player.positionSeconds)
            .clamp(0, double.infinity),
        playbackRate: player.speed,
      );
    });
    _resumeSaveTimer?.cancel();
    _resumeSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveResumePosition(player);
    });
  }

  int _sourceChapterIndexForPlayerIndex(
    AudioPlayerInterface player,
    int playerIndex,
  ) {
    final queueIndex = player.chapterIndexForPlayerIndex(playerIndex);
    if (queueIndex < 0 || queueIndex >= player.chapters.length) {
      return queueIndex;
    }
    return player.chapters[queueIndex].index;
  }

  void _saveResumePosition(AudioPlayerInterface player) {
    if (!mounted) return;
    final resume = ref.read(resumeStoreProvider);
    final playerIdx = player.currentIndexValue;
    if (playerIdx == null || !player.isPlaying) return;
    final router = ResumePositionRouter(
      playableChapters: List.of(_playableChapters),
    );
    final epubIdx = router.saveValueForPlayerIndex(playerIdx);
    if (epubIdx == null) return;
    resume.saveBookPosition(widget.bookId, epubIdx, player.positionSeconds);
  }

  Future<void> _restoreResumePosition(AudioPlayerInterface player) async {
    if (_resumeGuard.hasRestored) return;
    final resume = ref.read(resumeStoreProvider);
    final saved = resume.loadBookPosition(widget.bookId);
    if (saved == null) {
      return;
    }

    final router = ResumePositionRouter(
      playableChapters: List.of(_playableChapters),
    );
    // The guard latches: returns the queue index exactly once, when
    // the saved chapter has finally landed in the playable queue.
    // Subsequent calls (later SSE batches) return null so we never
    // jump the player backwards if the user already pressed play.
    final queueIdx = _resumeGuard.targetForSavedValue(saved.chapter, router);
    if (queueIdx == null) return;
    await player.seek(
      Duration(milliseconds: (saved.seconds * 1000).round()),
      index: queueIdx,
    );
  }

  void _markBookOffline() {
    final library = ref.read(libraryStoreProvider);
    final idx = library.books.indexWhere((b) => b.id == widget.bookId);
    if (idx < 0) return;
    final book = library.books[idx];
    if (!book.cachedOffline) {
      book.cachedOffline = true;
      library.update(book);
    }
  }

  void _cancelConversion() {
    _finishChapterPreparation(false);
    _playbackStartup.invalidate();
    _platformVoiceSession.end();
    _stopNativeConversion();
    _chapterIndexSub?.cancel();
    _chapterIndexSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _resumeSaveTimer?.cancel();
    _isConverting = false;
    _localConversionGeneration++;
    _localPlaybackConversion = null;
    _requestedPlaybackChapterIndex = null;
    _readerListeningPosition = null;
    _readerStartGeneration = null;
    _closePlaybackWindowChanges(recreate: true);

    _playableChapters.clear();
    _resumeGuard = ResumeRestorationGuard();
  }

  void _stopNativeConversion() {
    final service = _activeConversionService;
    if (service != null) unawaited(service.cancel());
  }

  void _publishPlaybackWindow(int chapterIndex) {
    if (chapterIndex < 0 || _requestedPlaybackChapterIndex == chapterIndex) {
      return;
    }
    _requestedPlaybackChapterIndex = chapterIndex;
    if (!_playbackWindowChanges.isClosed) {
      _playbackWindowChanges.add(chapterIndex);
    }
  }

  void _closePlaybackWindowChanges({bool recreate = false}) {
    final stream = _playbackWindowChanges;
    _playbackWindowChanges = StreamController<int>.broadcast();
    unawaited(stream.close());
    if (!recreate) _playbackWindowChanges.close();
  }

  Future<void> _runLocalPlaybackConversion({
    required int playbackChapterIndex,
    required int generation,
    ReaderListeningPosition? readerPosition,
  });
}
