// Book open screen — mirrors iOS BookOpenView.
//
// Lifecycle:
//   1. Try cached fulltext (instant).
//   2. If no cache: parse EPUB through the selected native/runtime bridge, cache the result.
//   3. On success: render InstantReaderView.
//   4. Audio is NOT auto-started — user taps the global player.
//   5. Android/iOS conversion runs through the embedded Rust runtime.
//
// This widget is embedded inside the Reader tab (not pushed as a route)
// so the MiniPlayerBar and NavigationBar remain visible.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/book_entity.dart';
import '../models/job_snapshot.dart';
import '../services/async_load_guard.dart';
import '../services/audio_player_service.dart';
import '../services/cover_writeback.dart';

import '../services/local_conversion_job.dart';
import '../services/edge_chapter_conversion.dart';
import '../services/latency_observation.dart';

import '../services/playback_first_resource_policy.dart';

import '../services/speech_text_policy.dart';
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
  Future<void> Function()? _playbackRequest;
  final PlaybackFirstResourcePolicy _resourcePolicy =
      PlaybackFirstResourcePolicy();
  String? _readerJourneyId;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _playbackRequest = () async {
      if (!mounted) return;
      await _startConversion();
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(playbackRequestProvider.notifier).state = _playbackRequest;
      }
    });

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

  Future<void> _load() async {
    // didUpdateWidget can fire a new _load while a previous one is
    // still awaiting cache.read / embedded Rust parsing. Tag each load
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
    if (Platform.isAndroid) {
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
      final fulltext = await ref
          .read(embeddedConverterProvider)
          .parse(inputPath: filePath, jobId: loadingForBookId);
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
    if (!Platform.isAndroid) return;
    final speech = ref.read(androidSpeechFallbackProvider);
    var available = await speech.isAvailable();
    for (var attempt = 0; !available && attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      available = await speech.isAvailable();
    }
    if (!available) return;
    final chunks = <String>[];
    for (final chapter in fulltext.chapters) {
      chunks.addAll(SpeechTextPolicy.splitForAndroidTts(chapter.text));
    }
    if (chunks.isEmpty) return;
    final locale = SpeechTextPolicy.detectLocale(
      fulltext.chapters.map((chapter) => chapter.text),
    );
    debugPrint(
      'BookOpenScreen: Android TTS fallback locale=$locale chunks=${chunks.length}',
    );
    try {
      await const MethodChannel(
        'epub_to_mp3/android_tts',
      ).invokeMethod<void>('speakQueued', {'texts': chunks, 'locale': locale});
    } on PlatformException {
      await speech.speak(chunks.first, locale: locale);
    }
  }

  Future<void> _startConversion() async {
    debugPrint(
      'BookOpenScreen: start conversion requested for ${widget.bookId}',
    );
    final ft = _fulltext;
    if (ft == null || ft.chapters.isEmpty) return;
    if (mounted) setState(() => _isConverting = true);

    // Android uses the chapter-by-chapter local Edge path. The web/backend
    // path remains an explicit compatibility option for desktop only.
    if (Platform.isAndroid &&
        const String.fromEnvironment('EPUB_USE_NATIVE_MANIFEST') == '1') {
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
            manifestIsInline
                ? '$outputDir/$coverName'
                : '${manifestFile.parent.path}/$coverName',
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
          audioFiles.add(
            ChapterProgress(
              index: i,
              name: i < ft.chapters.length
                  ? ft.chapters[i].displayTitle
                  : 'Chapter ${i + 1}',
              status: 'completed',
              downloadUrl: audioFile.uri.toString(),
              progressRatio: 1.0,
            ),
          );
        }
        if (audioFiles.isEmpty) {
          throw StateError('Rust converter returned no valid chapter audio');
        }
        final audio = ref.read(globalAudioPlayerProvider);
        await audio.setQueue(audioFiles);
        if (audio.chapters.isEmpty) {
          throw StateError('Rust audio queue was empty after setQueue');
        }
        ref.read(currentlyPlayingBookIdProvider.notifier).state = widget.bookId;
        if (!mounted) return;
        setState(() {
          _isConverting = false;
          _playableChapters.addAll(audioFiles);
        });
      } catch (error) {
        debugPrint('BookOpenScreen: embedded conversion failed: $error');
        _showConversionError(error);
        if (!mounted) return;
        setState(() {
          _isConverting = false;
        });
      }
      return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      await _startLocalConversion();
      return;
    }
    // The external backend remains an explicit desktop compatibility path.
    try {
      await _startBackendConversion();
    } catch (error) {
      if (!mounted) return;
      _showConversionError(error);
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

  // ignore: unused_element
  Future<void> _startLocalConversion() async {
    final ft = _fulltext!;
    debugPrint(
      'BookOpenScreen: local conversion entered chapters=${ft.chapters.length}',
    );
    final coordinator = ConversionJobCoordinator(
      LocalConversionJobStore(ref.read(sharedPrefsProvider)),
    );
    final jobId = 'local-${widget.bookId}';
    try {
      final library = ref.read(libraryStoreProvider);
      final book = library.books
          .where((b) => b.id == widget.bookId)
          .firstOrNull;
      if (book == null) throw StateError('Book is no longer in the library');
      debugPrint('BookOpenScreen: local book resolved path=${book.filePath}');
      final docsDir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${docsDir.path}/audiobooks/${widget.bookId}');
      if (!await outDir.exists()) await outDir.create(recursive: true);
      debugPrint('BookOpenScreen: local output ready path=${outDir.path}');

      final player = ref.read(globalAudioPlayerProvider);
      _setCoverOnPlayer(player);

      final existingJob = await coordinator.store.load(widget.bookId, jobId);
      late LocalConversionJob job;
      if (existingJob == null ||
          existingJob.status == LocalConversionJobStatus.cancelled) {
        job = await coordinator.createJob(
          bookId: widget.bookId,
          jobId: jobId,
          // Fulltext indices are EPUB-axis identifiers and may repeat for
          // structural entries. Conversion output needs a dense, unique
          // playable axis so every chapter gets its own file and job record.
          chapters: [
            for (var i = 0; i < ft.chapters.length; i++)
              LocalConversionChapterSpec(i, ft.chapters[i].name ?? ''),
          ],
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
      final bookLocale = SpeechTextPolicy.detectLocale(
        ft.chapters.map((chapter) => chapter.text),
      );
      debugPrint('BookOpenScreen: verified book locale=$bookLocale');

      // Rebuild the queue from files already recorded as completed. A process
      // death therefore resumes at the first pending chapter, not chapter 0.
      final restoredAudioPaths = <String>{};
      for (final saved in job.chapters.where((c) => c.status == 'completed')) {
        final path = saved.outputPath;
        if (path == null || path.isEmpty || !await File(path).exists()) {
          continue;
        }
        // Older jobs could contain repeated EPUB structural index 0 entries.
        // Never enqueue the same physical MP3 repeatedly after migration.
        if (!restoredAudioPaths.add(path)) continue;
        final source = saved.index >= 0 && saved.index < ft.chapters.length
            ? ft.chapters[saved.index]
            : ft.chapters.where((c) => c.index == saved.index).firstOrNull;
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
      debugPrint(
        'BookOpenScreen: completed queue restored count=${_playableChapters.length}',
      );
      if (_playableChapters.isNotEmpty) {
        await player.setQueue(List.of(_playableChapters));
        await _restoreResumePosition(player);
        _startResumeListener(player);
        // The play button may have triggered this conversion request while
        // the queue was still empty. Start the first restored file now rather
        // than waiting for the entire book to finish converting.
      }
      // Persist a checkpoint even when the process resumes an existing job.
      // This recreates a missing manifest before the next long chapter starts.
      final restoredManifestTemp = File('${outDir.path}/manifest.json.part');
      await restoredManifestTemp.writeAsString(
        jsonEncode(job.toJson()),
        flush: true,
      );
      await restoredManifestTemp.rename('${outDir.path}/manifest.json');

      final converter = ref.read(embeddedConverterProvider);
      final conversionService = EdgeChapterConversionService(
        converter: converter,
        coordinator: coordinator,
      );
      final conversionChapters = [
        for (var i = 0; i < ft.chapters.length; i++)
          FulltextChapter(
            index: i,
            name: ft.chapters[i].name,
            text: ft.chapters[i].text,
          ),
      ];
      job = await conversionService.convert(
        bookId: widget.bookId,
        jobId: jobId,
        chapters: conversionChapters,
        outputDirectory: outDir.path,
        onUpdate: (updated) async {
          if (!mounted) return;
          setState(() => _localJob = updated);
        },
        onChapterCompleted: (chapter, path, updated) async {
          if (!mounted) return;
          final isFirstPlayableChapter = _playableChapters.isEmpty;
          final cp = ChapterProgress(
            index: chapter.index,
            name: chapter.name,
            status: 'completed',
            downloadUrl: 'file://$path',
            chars: chapter.text.length,
            progressRatio: 1.0,
          );
          if (!_playableChapters.any((c) => c.index == cp.index)) {
            _playableChapters.add(cp);
            _playableChapters.sort((a, b) => a.index.compareTo(b.index));
          }
          await player.setQueue(List.of(_playableChapters));
          if (isFirstPlayableChapter) {
            await _restoreResumePosition(player);
            _startResumeListener(player);
          }
          _localJob = updated;
        },
      );
      _localJob = job;

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
        final player = ref.read(globalAudioPlayerProvider);
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
            child: Stack(
              children: [
                InstantReaderView(
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
                if (_isConverting)
                  const Positioned(
                    right: 24,
                    bottom: 24,
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
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
