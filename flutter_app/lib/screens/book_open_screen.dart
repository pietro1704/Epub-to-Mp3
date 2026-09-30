// Book open screen — mirrors iOS BookOpenView.
//
// Lifecycle:
//   1. Try cached fulltext (instant).
//   2. If no cache: parse EPUB through the selected native/runtime bridge, cache the result.
//   3. On success: render InstantReaderView.
//   4. Audio is NOT auto-started — user taps play.
//   5. Play triggers upload+convert via backend, SSE streams progress.
//
// This widget is embedded inside the Reader tab (not pushed as a route)
// so the MiniPlayerBar and NavigationBar remain visible.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/book_entity.dart';
import '../models/job_snapshot.dart';
import '../services/async_load_guard.dart';
import '../services/audio_player_service.dart';
import '../services/cover_writeback.dart';
import '../services/python_bridge.dart';
import '../services/local_conversion_job.dart';
import '../services/latency_observation.dart';
import '../services/background_conversion_scheduler.dart';
import '../services/playback_first_resource_policy.dart';
import '../services/protected_audio_storage_guard.dart';
import '../services/resume_position_router.dart';
import '../services/resume_restoration_guard.dart';
import '../services/sse_subscription_lifecycle.dart';
import '../state/providers.dart';
import '../views/instant_reader_view.dart';
import 'library_screen.dart';
import 'pdf_reader_screen.dart';

enum _Phase { resolving, ready, error }

class BookOpenScreen extends ConsumerStatefulWidget {
  const BookOpenScreen({super.key, required this.bookId});
  final String bookId;

  @override
  ConsumerState<BookOpenScreen> createState() => _BookOpenScreenState();
}

class _BookOpenScreenState extends ConsumerState<BookOpenScreen>
    with WidgetsBindingObserver {
  _Phase _phase = _Phase.resolving;
  EbookFulltext? _fulltext;
  String? _errorMessage;

  // Local conversion state
  bool _isConverting = false;
  final List<ChapterProgress> _playableChapters = [];
  LocalConversionJob? _localJob;
  ResumeRestorationGuard _resumeGuard = ResumeRestorationGuard();
  final AsyncLoadGuard _loadGuard = AsyncLoadGuard();
  StreamSubscription<JobSnapshot>? _sseSubscription;
  StreamSubscription<int?>? _chapterIndexSub;
  StreamSubscription<Duration>? _positionSub;
  Timer? _resumeSaveTimer;
  Future<void> _snapshotWork = Future.value();
  final PlaybackFirstResourcePolicy _resourcePolicy =
      PlaybackFirstResourcePolicy();
  String? _readerJourneyId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final book = ref
        .read(libraryStoreProvider)
        .books
        .where((b) => b.id == widget.bookId)
        .firstOrNull;
    if (book == null || !isPdfFilePath(book.filePath)) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant BookOpenScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId) {
      _cancelConversion();
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sseSubscription?.cancel();
    _chapterIndexSub?.cancel();
    _chapterIndexSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _resumeSaveTimer?.cancel();
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    _resourcePolicy.recordMemoryPressure();
  }

  Future<bool> _waitForConversionResourceWindow(
    AudioPlayerInterface player,
  ) async {
    while (mounted && _isConverting) {
      final reason = _resourcePolicy.yieldReason(
        playbackActive: player.isPlaying,
        pendingNavigation: false,
      );
      if (reason == null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<void> _load() async {
    // didUpdateWidget can fire a new _load while a previous one is
    // still awaiting cache.read / bridge.parseEpub. Tag each load
    // with a generation token so the stale continuation skips its
    // setState and does not flash the previous book's content onto
    // the newly-mounted bookId.
    final gen = _loadGuard.start();
    _readerJourneyId = latencyObservations.begin(
      LatencyJourneyKind.readerOpen,
      LatencyTransition.interactionRequested,
    );
    final loadingForBookId = widget.bookId;
    setState(() {
      _phase = _Phase.resolving;
      _fulltext = null;
      _errorMessage = null;
    });

    final cache = ref.read(localFulltextCacheProvider);

    // 1) Try cached fulltext.
    final cached = await cache.read(loadingForBookId);
    if (!mounted || !_loadGuard.isCurrent(gen)) return;
    if (cached != null) {
      setState(() {
        _fulltext = cached;
        _phase = _Phase.ready;
      });
      _markBookOpened();
      _completeReaderJourney();
      return;
    }

    // 2) Parse through the selected local runtime. Embedded Android mode
    // never routes a local EPUB through the HTTP backend.
    final settings = ref.read(settingsProvider);
    if (Platform.isAndroid && settings.useEmbeddedRuntime) {
      try {
        final library = ref.read(libraryStoreProvider);
        final book = library.books
            .where((b) => b.id == loadingForBookId)
            .firstOrNull;
        if (book == null) throw StateError('Book is no longer in the library');
        final path = await library.ensureSupportedBookPath(book);
        final fulltext = await ref
            .read(embeddedConverterProvider)
            .parse(inputPath: path, jobId: loadingForBookId);
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        await cache.save(fulltext, loadingForBookId);
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        setState(() {
          _fulltext = fulltext;
          _phase = _Phase.ready;
        });
        _markBookOpened();
        _completeReaderJourney();
      } catch (error) {
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        setState(() {
          _errorMessage = error.toString();
          _phase = _Phase.error;
        });
        _cancelReaderJourney();
      }
      return;
    }

    final bridge = PythonBridge();
    if (!bridge.isSupported) {
      // On platforms where Python is not available, show the text from
      // cache only. If there's no cache we show an informative error.
      if (!mounted || !_loadGuard.isCurrent(gen)) return;
      setState(() {
        _errorMessage = 'EPUB parsing is not available on this platform';
        _phase = _Phase.error;
      });
      _cancelReaderJourney();
      return;
    }

    try {
      final library = ref.read(libraryStoreProvider);
      // Null-safe lookup: the user can remove the book from the library
      // (or the library can fail to load it) between BookOpenScreen
      // mounting and this async path running. firstWhere without
      // orElse would throw StateError and crash the parse flow.
      final book = library.books
          .where((b) => b.id == loadingForBookId)
          .firstOrNull;
      if (book == null) {
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        setState(() {
          _errorMessage = 'Book is no longer in the library';
          _phase = _Phase.error;
        });
        _cancelReaderJourney();
        return;
      }
      final filePath = await library.ensureSupportedBookPath(book);
      final fulltext = await bridge.parseEpub(
        filePath,
        jobId: loadingForBookId,
      );
      if (!mounted || !_loadGuard.isCurrent(gen)) return;
      await cache.save(fulltext, loadingForBookId);
      if (!mounted || !_loadGuard.isCurrent(gen)) return;
      setState(() {
        _fulltext = fulltext;
        _phase = _Phase.ready;
      });
      _markBookOpened();
      _completeReaderJourney();
    } catch (e) {
      if (!mounted || !_loadGuard.isCurrent(gen)) return;
      setState(() {
        _errorMessage = e.toString();
        _phase = _Phase.error;
      });
      _cancelReaderJourney();
    }
  }

  void _completeReaderJourney() {
    final id = _readerJourneyId;
    if (id == null) return;
    latencyObservations.record(id, LatencyTransition.readerUsable);
    latencyObservations.finish(id);
    _readerJourneyId = null;
  }

  void _cancelReaderJourney() {
    final id = _readerJourneyId;
    if (id == null) return;
    latencyObservations.cancel(id);
    _readerJourneyId = null;
  }

  void _markBookOpened() {
    final library = ref.read(libraryStoreProvider);
    final idx = library.books.indexWhere((b) => b.id == widget.bookId);
    if (idx >= 0) {
      final book = library.books[idx];
      book.lastOpenedAt = DateTime.now();
      library.update(book);
    }
  }

  Future<void> _speakCurrentChapterOffline() async {
    final fulltext = _fulltext;
    if (fulltext == null || fulltext.chapters.isEmpty) return;
    final chapter = fulltext.chapters.firstWhere(
      (candidate) => candidate.text.trim().isNotEmpty,
      orElse: () => fulltext.chapters.first,
    );
    if (!Platform.isAndroid) return;
    // Embedded mode must never fall back to Android TextToSpeech.
    final settings = ref.read(settingsProvider);
    if (settings.useEmbeddedRuntime) {
      if (!mounted) return;
      if (mounted) setState(() {});
      return;
    }
    final engine = ref.read(androidSpeechFallbackProvider);
    if (!await engine.isAvailable() || !mounted) return;
    await engine.speak(chapter.text, locale: _offlineLocale(chapter.text));
  }

  String _offlineLocale(String text) {
    final lower = text.toLowerCase();
    if (RegExp(r'\b(the|and|this|that)\b').hasMatch(lower)) return 'en-US';
    if (RegExp(r'\b(el|la|los|una|que)\b').hasMatch(lower)) return 'es-ES';
    if (RegExp(r'\b(le|une|les|des|que)\b').hasMatch(lower)) return 'fr-FR';
    return 'pt-BR';
  }

  static const _defaultVoices = <String, String>{
    'pt': 'pt-BR-AntonioNeural',
    'en': 'en-US-GuyNeural',
    'es': 'es-MX-JorgeNeural',
    'fr': 'fr-FR-HenriNeural',
    'de': 'de-DE-ConradNeural',
    'it': 'it-IT-DiegoNeural',
    'ja': 'ja-JP-KeitaNeural',
    'zh': 'zh-CN-YunxiNeural',
  };

  // ignore: unused_element
  Future<void> _startConversion() async {
    if (_isConverting) return;
    debugPrint('BookOpenScreen: start conversion requested for ${widget.bookId}');
    final ft = _fulltext;
    if (ft == null || ft.chapters.isEmpty) return;

    setState(() {
      _isConverting = true;
      _playableChapters.clear();
      // Reset the latched guard so the resume restoration retries for
      // the new conversion run.
      _resumeGuard = ResumeRestorationGuard();
    });

    final settings = ref.read(settingsProvider);
    if (Platform.isAndroid && settings.useEmbeddedRuntime) {
      try {
        final library = ref.read(libraryStoreProvider);
        final book = library.books
            .where((b) => b.id == widget.bookId)
            .firstOrNull;
        if (book == null) throw StateError('Book is no longer in the library');
        final path = await library.ensureSupportedBookPath(book);
        final outputDir =
            '${(await getApplicationDocumentsDirectory()).path}/audiobooks/${widget.bookId}';
        final manifest = await ref
            .read(embeddedConverterProvider)
            .convert(inputPath: path, outputPath: outputDir);
        debugPrint('Embedded conversion returned ${manifest.length} bytes');
        final manifestFile = File(manifest);
        final manifestIsInline = manifest.trimLeft().startsWith('{');
        if (!manifestIsInline && !await manifestFile.exists()) {
          throw StateError('Rust converter returned a missing manifest');
        }
        final manifestData = jsonDecode(
          manifestIsInline ? manifest : await manifestFile.readAsString(),
        );
        if (manifestData is! Map<String, dynamic>) {
          throw StateError('Rust converter returned invalid manifest JSON');
        }
        final coverName = manifestData['cover'] as String?;
        if (coverName != null && coverName.isNotEmpty) {
          final coverFile = File(
            manifestIsInline ? '$outputDir/$coverName' : '${manifestFile.parent.path}/$coverName',
          );
          if (await coverFile.exists()) {
            final bytes = await coverFile.readAsBytes();
            final book = ref
                .read(libraryStoreProvider)
                .books
                .where((b) => b.id == widget.bookId)
                .firstOrNull;
            if (book != null && book.coverBase64 == null) {
              book.coverBase64 = base64Encode(bytes);
              ref.read(libraryStoreProvider).update(book);
            }
          }
        }
        final chapterEntries = manifestData['chapters'];
        if (chapterEntries is! List || chapterEntries.isEmpty) {
          throw StateError('Rust converter returned no playable chapters');
        }
        final audioFiles = <ChapterProgress>[];
        for (var i = 0; i < chapterEntries.length; i++) {
          final entry = chapterEntries[i];
          if (entry is! Map<String, dynamic>) continue;
          final rawPath = entry['path'] ?? entry['audioPath'] ?? entry['file'];
          if (rawPath is! String || rawPath.isEmpty) continue;
          final audioFile = File(
            rawPath.startsWith('/') ? rawPath : '$outputDir/$rawPath',
          );
          if (!await audioFile.exists() || await audioFile.length() == 0) {
            throw StateError('Rust converter returned invalid chapter audio');
          }
          audioFiles.add(ChapterProgress(
            index: i,
            name: i < ft.chapters.length ? ft.chapters[i].displayTitle : 'Chapter ${i + 1}',
            status: 'completed',
            downloadUrl: audioFile.uri.toString(),
            progressRatio: 1.0,
          ));
        }
        if (audioFiles.isEmpty) {
          throw StateError('Rust converter returned no valid chapter audio');
        }
        final audio = ref.read(globalAudioPlayerProvider);
        await audio.setQueue(audioFiles);
        await audio.play();
        ref.read(currentlyPlayingBookIdProvider.notifier).state = widget.bookId;
        if (!mounted) return;
        setState(() {
          _isConverting = false;
          _playableChapters.addAll(audioFiles);
        });
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _isConverting = false;
        });
      }
      return;
    }
    if (settings.useEmbeddedRuntime && !Platform.isAndroid) {
      final bridge = PythonBridge();
      if (!bridge.isSupported) {
        setState(() {
          _isConverting = false;
        });
        return;
      }
      await _startLocalConversion(bridge);
      return;
    }

    // The external backend is an explicit settings opt-in. Do not silently
    // fall back to it after a local conversion error because that would send
    // the book off-device against the selected provider policy.
    try {
      await _startBackendConversion();
    } catch (error) {
      if (!mounted) return;
      unawaited(_speakCurrentChapterOffline());
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

  Future<void> _startLocalConversion(PythonBridge bridge) async {
    final ft = _fulltext!;
    final coordinator = ConversionJobCoordinator(
      LocalConversionJobStore(ref.read(sharedPrefsProvider)),
    );
    final jobId = 'local-${widget.bookId}';
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${docsDir.path}/audiobooks/${widget.bookId}');
      if (!await outDir.exists()) await outDir.create(recursive: true);

      final sample = ft.chapters.first.text.substring(
        0,
        ft.chapters.first.text.length.clamp(0, 500),
      );
      final lang = await bridge.detectLanguage(sample);
      final voice = _defaultVoices[lang] ?? _defaultVoices['pt']!;
      final scheduler = BackgroundConversionScheduler();
      final storageGuard = ProtectedAudioStorageGuard();
      final player = ref.read(globalAudioPlayerProvider);
      _setCoverOnPlayer(player);

      final existingJob = await coordinator.store.load(widget.bookId, jobId);
      late LocalConversionJob job;
      if (existingJob == null ||
          existingJob.status == LocalConversionJobStatus.cancelled) {
        job = await coordinator.createJob(
          bookId: widget.bookId,
          jobId: jobId,
          chapters: ft.chapters
              .map((ch) => LocalConversionChapterSpec(ch.index, ch.name ?? ''))
              .toList(),
        );
      } else {
        job = existingJob;
        job = await coordinator.watchdog(job);
        for (final chapter in job.chapters.where((c) => c.status == 'failed')) {
          job = await coordinator.retryChapter(job, chapter.index);
        }
      }
      for (final chapter in job.chapters.where((c) => c.status == 'running')) {
        final path = '${outDir.path}/chapter_${chapter.index}.mp3';
        if (await File(path).exists()) {
          job = await coordinator.completeChapter(job, chapter.index, path);
        }
      }
      _localJob = job;

      // Rebuild the queue from files already recorded as completed. A process
      // death therefore resumes at the first pending chapter, not chapter 0.
      for (final saved in job.chapters.where((c) => c.status == 'completed')) {
        final path = saved.outputPath;
        if (path == null || path.isEmpty || !await File(path).exists()) {
          continue;
        }
        final source = ft.chapters
            .where((c) => c.index == saved.index)
            .firstOrNull;
        _playableChapters.add(
          ChapterProgress(
            index: saved.index,
            name: source?.name ?? saved.name,
            status: 'completed',
            downloadUrl: 'file://$path',
            chars: source?.text.length,
            progressRatio: 1.0,
          ),
        );
      }
      _playableChapters.sort((a, b) => a.index.compareTo(b.index));
      if (_playableChapters.isNotEmpty) {
        await player.setQueue(List.of(_playableChapters));
        await _restoreResumePosition(player);
        _startResumeListener(player);
      }

      for (var i = 0; i < ft.chapters.length; i++) {
        if (!mounted || !_isConverting) return;
        if (!await _waitForConversionResourceWindow(player)) return;
        final ch = ft.chapters[i];
        final saved = job.chapters
            .where((c) => c.index == ch.index)
            .firstOrNull;
        if (saved?.status == 'completed') {
          continue;
        }

        job = await coordinator.markChapterRunning(job, ch.index);
        _localJob = job;
        final mp3Path = '${outDir.path}/chapter_${ch.index}.mp3';
        if (ch.text.trim().isEmpty) {
          job = await coordinator.completeChapter(job, ch.index, mp3Path);
          _localJob = job;

          continue;
        }

        await storageGuard.ensureCanRetain(
          estimatedBytes: ProtectedAudioStorageGuard.estimateChapterAudioBytes(
            ch.text,
          ),
        );

        Map<String, dynamic> result;
        if (scheduler.isSupported) {
          final workerId = '$jobId-${ch.index}';
          final queued = await scheduler.enqueueChapter(
            jobId: workerId,
            text: ch.text,
            voice: voice,
            outputPath: mp3Path,
          );
          if (!queued) {
            throw StateError('Could not enqueue background conversion');
          }
          final deadline = DateTime.now().add(const Duration(minutes: 30));
          while (!await File(mp3Path).exists() &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
          result = await File(mp3Path).exists()
              ? <String, dynamic>{'ok': true, 'path': mp3Path}
              : <String, dynamic>{
                  'ok': false,
                  'error': 'Background conversion timed out',
                };
        } else {
          result = await bridge.convertChapter(
            text: ch.text,
            outputPath: mp3Path,
            voice: voice,
          );
        }
        if (!mounted) return;
        if (result['ok'] != true) {
          final error =
              result['error']?.toString() ?? 'Chapter conversion failed';
          _localJob = await coordinator.failChapter(job, ch.index, error);
          throw StateError(error);
        }

        final cp = ChapterProgress(
          index: ch.index,
          name: ch.name,
          status: 'completed',
          downloadUrl: 'file://$mp3Path',
          chars: ch.text.length,
          progressRatio: 1.0,
        );
        final isFirstPlayableChapter = _playableChapters.isEmpty;
        if (!_playableChapters.any((c) => c.index == cp.index)) {
          _playableChapters.add(cp);
          _playableChapters.sort((a, b) => a.index.compareTo(b.index));
        }
        await player.setQueue(List.of(_playableChapters));
        if (isFirstPlayableChapter) {
          await _restoreResumePosition(player);
          _startResumeListener(player);
        }
        job = await coordinator.completeChapter(job, ch.index, mp3Path);
        _localJob = job;

      }

      if (!mounted) return;
      _markBookOffline();
      setState(() => _isConverting = false);
    } catch (e) {
      if (_localJob != null &&
          _localJob!.status == LocalConversionJobStatus.running) {
        _localJob = await coordinator.failChapter(
          _localJob!,
          _localJob!.currentChapterIndex ?? 0,
          e.toString(),
        );
      }
      if (!mounted) return;
      setState(() => _isConverting = false);
    }
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
    _chapterIndexSub = player.currentIndex.listen((_) {
      // Keep the subscription lifecycle aligned with the reader screen.
    });
    _resumeSaveTimer?.cancel();
    _resumeSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveResumePosition(player);
    });
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
    _sseSubscription?.cancel();
    _sseSubscription = null;
    _chapterIndexSub?.cancel();
    _chapterIndexSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _resumeSaveTimer?.cancel();
    _isConverting = false;

    _playableChapters.clear();
    _resumeGuard = ResumeRestorationGuard();
  }


  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final library = ref.watch(libraryStoreProvider);
    BookEntity? book;
    for (final candidate in library.books) {
      if (candidate.id == widget.bookId) {
        book = candidate;
        break;
      }
    }
    final bookTitle = book?.resolvedTitle ?? '';

    if (book != null && isPdfFilePath(book.filePath)) {
      return PdfReaderScreen(
        bookId: widget.bookId,
        title: bookTitle,
        filePath: book.filePath,
        prefs: ref.watch(sharedPrefsProvider),
      );
    }

    switch (_phase) {
      case _Phase.resolving:
        return Scaffold(
          appBar: AppBar(title: Text(bookTitle)),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(t.parsingBook),
              ],
            ),
          ),
        );

      case _Phase.error:
        return Scaffold(
          appBar: AppBar(title: Text(bookTitle)),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  t.parsingFailed,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: Text(t.retry),
                ),
              ],
            ),
          ),
        );

      case _Phase.ready:
        final coverArt = book?.coverBase64 != null
            ? _decodeCover(book!.coverBase64!)
            : null;
        final player = (_isConverting || _playableChapters.isNotEmpty)
            ? ref.read(globalAudioPlayerProvider)
            : null;
        return Scaffold(
          appBar: AppBar(
            title: Text(bookTitle),
            titleTextStyle: Theme.of(context).textTheme.titleMedium,
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _resourcePolicy.recordReaderInteraction(),
            onPointerMove: (_) => _resourcePolicy.recordReaderInteraction(),
            child: InstantReaderView(
              fulltext: _fulltext!,
              bookId: widget.bookId,
              coverArt: coverArt,
              player: player,
              initialChapterIndex: _playableChapters.isEmpty
                  ? 0
                  : ResumePositionRouter(
                          playableChapters: List.of(_playableChapters),
                        ).queueIndexForSavedValue(
                          ref
                                  .read(resumeStoreProvider)
                                  .loadBookPosition(widget.bookId)
                                  ?.chapter ??
                              0,
                        ) ??
                        0,
            ),
          ),
        );
    }
  }

  static Uint8List? _decodeCover(String base64str) {
    try {
      return base64Decode(base64str);
    } catch (_) {
      return null;
    }
  }
}
