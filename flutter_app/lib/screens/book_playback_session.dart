part of 'book_open_screen.dart';

mixin BookPlaybackSession on ConsumerState<BookOpenScreen>, BookContentSession {

  // Local conversion state
  bool _isConverting = false;
  final List<ChapterProgress> _playableChapters = [];
  LocalConversionJob? _localJob;
  ResumeRestorationGuard _resumeGuard = ResumeRestorationGuard();
  StreamSubscription<JobSnapshot>? _sseSubscription;
  StreamSubscription<int?>? _chapterIndexSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _resumeSaveTimer;
  Future<void> _snapshotWork = Future.value();
  Future<void> Function()? _playbackRequest;
  StreamController<int> _playbackWindowChanges =
      StreamController<int>.broadcast();
  Future<void>? _localPlaybackConversion;
  int _localConversionGeneration = 0;
  int? _requestedPlaybackChapterIndex;
  final PlaybackFirstResourcePolicy _resourcePolicy =
      PlaybackFirstResourcePolicy();
  StreamSubscription<dynamic>? _platformVoiceSubscription;
  final _platformVoiceSession = PlatformVoiceNoticeSession();
  final _playbackStartup = ReaderPlaybackStartup();
  RustPlaybackConversionService? _activeConversionService;


  void _showConversionError(Object error) {
    if (!mounted) return;
    final detail = error.toString();
    final l10n = AppLocalizations.of(context)!;
    final message =
        detail.contains('NO_MODEL') ||
            detail.contains('ENGINE_UNAVAILABLE') ||
            detail.contains('No TTS engine')
        ? '${l10n.conversionFailed}: ${l10n.settingsTitle}'
        : '${l10n.conversionFailed}: $detail';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
      await _startLocalConversion(
        playbackChapterIndex:
            _playableChapters.isEmpty || player.currentIndexValue == null
            ? savedChapter ?? 0
            : _sourceChapterIndexForPlayerIndex(
                player,
                player.currentIndexValue!,
              ),
      );
      return;
    }
    // Unsupported companion shells must opt into legacy HTTP compatibility.
    if (ref.read(settingsProvider).useEmbeddedRuntime) {
      _showConversionError(
        EmbeddedConverterUnavailable(
          'No local Rust audio adapter is registered for this platform.',
        ),
      );
      if (mounted) setState(() => _isConverting = false);
      return;
    }
    try {
      await _startBackendConversion();
    } catch (error) {
      if (!mounted) return;
      _showConversionError(error);
      setState(() {
        _isConverting = false;
      });
    }
  }

  Future<void> _startBackendConversion() async {
    final api = ref.read(apiClientProvider);
    final library = ref.read(libraryStoreProvider);
    // Null-safe lookup mirrors the _load() guard. Same race: the
    // book can disappear from the library between the user tapping
    // play and this method running.
    final book = library.books.where((b) => b.id == widget.bookId).firstOrNull;
    if (book == null) {
      throw StateError('Book is no longer in the library');
    }

    final jobId = await api.uploadAndConvert(book.filePath);

    book.lastJobId = jobId;
    library.update(book);

    _sseSubscription?.cancel();
    _sseSubscription = SseSubscriptionLifecycle.listen(
      api.jobStream(jobId),
      onData: _enqueueSnapshot,
      onError: (Object e) {
        _sseSubscription = null;
        if (!mounted) return;
        setState(() {
          _isConverting = false;
        });
      },
      onDone: () {
        _sseSubscription = null;
        if (!mounted) return;
        setState(() => _isConverting = false);
      },
    );
  }

  void _enqueueSnapshot(JobSnapshot snapshot) {
    // SSE can deliver the next chapter before asynchronous queue updates for
    // the previous one complete. Process snapshots in order so each update
    // appends to the same audio queue instead of racing a replacement.
    _snapshotWork = _snapshotWork.then((_) async {
      try {
        await _handleSnapshot(snapshot);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _isConverting = false;
        });
      }
    });
  }

  Future<void> _handleSnapshot(JobSnapshot snapshot) async {
    if (!mounted) return;

    final playable = snapshot.playableChapters;
    final newChapters = playable
        .where((c) => !_playableChapters.any((e) => e.index == c.index))
        .toList();

    if (newChapters.isNotEmpty) {
      final isFirstPlayableBatch = _playableChapters.isEmpty;
      _playableChapters.addAll(newChapters);
      _playableChapters.sort((a, b) => a.index.compareTo(b.index));

      final player = ref.read(globalAudioPlayerProvider);
      _setCoverOnPlayer(player);
      await player.setQueue(List.of(_playableChapters));
      if (!mounted) return;
      if (isFirstPlayableBatch) {
        await _restoreResumePosition(player);
        _startResumeListener(player);
        // Starting a conversion is explicit user intent. Queue readiness must
        // not turn into an implicit playback request on Android.
        // The user starts playback from the reader controls.
      }
    }

    if (snapshot.coverUrl != null) {
      _fetchBackendCover(snapshot.coverUrl!);
    }

    if (snapshot.isTerminal) {
      _sseSubscription?.cancel();
      _sseSubscription = null;
      if (snapshot.state.toLowerCase() == 'failed') {
        setState(() => _isConverting = false);
      } else {
        setState(() => _isConverting = false);
      }
    }
  }

  Future<void> _fetchBackendCover(String coverUrl) async {
    final library = ref.read(libraryStoreProvider);
    // Cheap pre-check to avoid the network call when we already have
    // a cover. The actual race-safe writeback happens after the
    // await via CoverWriteback (re-looks up by id).
    final existing = library.books
        .where((b) => b.id == widget.bookId)
        .firstOrNull;
    if (existing == null || existing.coverBase64 != null) return;

    try {
      final api = ref.read(apiClientProvider);
      final bytes = await api.fetchBytes(coverUrl);
      if (bytes == null || bytes.isEmpty || !mounted) return;
      CoverWriteback.apply(
        library: library,
        bookId: widget.bookId,
        coverBase64: base64Encode(bytes),
      );
    } catch (_) {}
  }

  Future<void> _startLocalConversion({required int playbackChapterIndex}) {
    _publishPlaybackWindow(playbackChapterIndex);
    final existing = _localPlaybackConversion;
    if (existing != null) return existing;
    final generation = ++_localConversionGeneration;
    _playbackStartup.request(generation, playbackChapterIndex);
    final future =
        _runLocalPlaybackConversion(
          playbackChapterIndex: playbackChapterIndex,
          generation: generation,
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
              await _restoreResumePosition(player);
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
    final library = ref.read(libraryStoreProvider);
    final idx = library.books.indexWhere((b) => b.id == widget.bookId);
    if (idx < 0) return;
    final book = library.books[idx];
    if (book.coverBase64 != null && player.coverArtData == null) {
      try {
        player.coverArtData = base64Decode(book.coverBase64!);
      } catch (_) {}
    }
  }

  void _startResumeListener(AudioPlayerInterface player) {
    _positionSub?.cancel();
    _positionSub = null;
    _chapterIndexSub?.cancel();
    _chapterIndexSub = player.currentIndex.listen((playerIndex) {
      if (playerIndex == null) return;
      _publishPlaybackWindow(
        _sourceChapterIndexForPlayerIndex(player, playerIndex),
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
    _playbackStartup.invalidate();
    _platformVoiceSession.end();
    _stopNativeConversion();
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _chapterIndexSub?.cancel();
    _chapterIndexSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _resumeSaveTimer?.cancel();
    _isConverting = false;
    _localConversionGeneration++;
    _localPlaybackConversion = null;
    _requestedPlaybackChapterIndex = null;
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


  Future<void> _runLocalPlaybackConversion({required int playbackChapterIndex, required int generation});
}
