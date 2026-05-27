// Book open screen — mirrors iOS BookOpenView.
//
// Lifecycle:
//   1. Try cached fulltext (instant).
//   2. If no cache: parse EPUB via PythonBridge, cache the result.
//   3. On success: render InstantReaderView.
//   4. Audio is NOT auto-started — user taps play.
//   5. Play triggers upload+convert via backend, SSE streams progress.
//
// This widget is embedded inside the Reader tab (not pushed as a route)
// so the MiniPlayerBar and NavigationBar remain visible.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import '../services/audio_player_service.dart';
import '../services/python_bridge.dart';
import '../services/resume_position_router.dart';
import '../services/resume_restoration_guard.dart';
import '../state/providers.dart';
import '../views/instant_reader_view.dart';
import 'library_screen.dart';

enum _Phase { resolving, ready, error }

class BookOpenScreen extends ConsumerStatefulWidget {
  const BookOpenScreen({super.key, required this.bookId});
  final String bookId;

  @override
  ConsumerState<BookOpenScreen> createState() => _BookOpenScreenState();
}

class _BookOpenScreenState extends ConsumerState<BookOpenScreen> {
  _Phase _phase = _Phase.resolving;
  EbookFulltext? _fulltext;
  String? _errorMessage;

  // Local conversion state
  bool _isConverting = false;
  String? _conversionError;
  int _chaptersConverted = 0;
  int _chaptersTotal = 0;
  final List<ChapterProgress> _playableChapters = [];
  ResumeRestorationGuard _resumeGuard = ResumeRestorationGuard();
  StreamSubscription<JobSnapshot>? _sseSubscription;
  StreamSubscription<Duration>? _positionSub;
  Timer? _resumeSaveTimer;

  @override
  void initState() {
    super.initState();
    _load();
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
    _sseSubscription?.cancel();
    _positionSub?.cancel();
    _resumeSaveTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.resolving;
      _fulltext = null;
      _errorMessage = null;
    });

    final cache = ref.read(localFulltextCacheProvider);

    // 1) Try cached fulltext.
    final cached = await cache.read(widget.bookId);
    if (cached != null) {
      if (!mounted) return;
      setState(() {
        _fulltext = cached;
        _phase = _Phase.ready;
      });
      _markBookOpened();
      return;
    }

    // 2) Parse via PythonBridge.
    final bridge = PythonBridge();
    if (!bridge.isSupported) {
      // On platforms where Python is not available, show the text from
      // cache only. If there's no cache we show an informative error.
      if (!mounted) return;
      setState(() {
        _errorMessage = 'EPUB parsing is not available on this platform';
        _phase = _Phase.error;
      });
      return;
    }

    try {
      final library = ref.read(libraryStoreProvider);
      final book = library.books.firstWhere((b) => b.id == widget.bookId);
      final filePath = book.filePath;
      final fulltext = await bridge.parseEpub(filePath, jobId: widget.bookId);
      await cache.save(fulltext, widget.bookId);
      if (!mounted) return;
      setState(() {
        _fulltext = fulltext;
        _phase = _Phase.ready;
      });
      _markBookOpened();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _phase = _Phase.error;
      });
    }
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

  Future<void> _startConversion() async {
    if (_isConverting) return;
    final ft = _fulltext;
    if (ft == null || ft.chapters.isEmpty) return;

    setState(() {
      _isConverting = true;
      _conversionError = null;
      _chaptersConverted = 0;
      _chaptersTotal = ft.chapters.length;
      _playableChapters.clear();
      // Reset the latched guard so the resume restoration retries for
      // the new conversion run.
      _resumeGuard = ResumeRestorationGuard();
    });

    ref.read(currentlyPlayingBookIdProvider.notifier).state = widget.bookId;

    // Try backend streaming first
    try {
      await _startBackendConversion();
      return;
    } catch (_) {
      if (!mounted) return;
    }

    // Fall back to on-device PythonBridge
    final bridge = PythonBridge();
    if (!bridge.isSupported) {
      setState(() {
        _isConverting = false;
        _conversionError = 'Backend unreachable and local Python not available';
      });
      return;
    }
    await _startLocalConversion(bridge);
  }

  Future<void> _startBackendConversion() async {
    final api = ref.read(apiClientProvider);
    final library = ref.read(libraryStoreProvider);
    final book = library.books.firstWhere((b) => b.id == widget.bookId);

    final jobId = await api.uploadAndConvert(book.filePath);

    book.lastJobId = jobId;
    library.update(book);

    _sseSubscription?.cancel();
    _sseSubscription = api
        .jobStream(jobId)
        .listen(
          _handleSnapshot,
          onError: (Object e) {
            if (!mounted) return;
            setState(() {
              _isConverting = false;
              _conversionError = e.toString();
            });
          },
          onDone: () {
            if (!mounted) return;
            setState(() => _isConverting = false);
          },
        );
  }

  void _handleSnapshot(JobSnapshot snapshot) {
    if (!mounted) return;

    final playable = snapshot.playableChapters;
    final newChapters = playable
        .where((c) => !_playableChapters.any((e) => e.index == c.index))
        .toList();

    if (newChapters.isNotEmpty) {
      _playableChapters.addAll(newChapters);
      _playableChapters.sort((a, b) => a.index.compareTo(b.index));

      final player = ref.read(globalAudioPlayerProvider);
      _setCoverOnPlayer(player);
      player.setQueue(List.of(_playableChapters));
      // No auto-play. Loading the queue is intentional, but playback
      // only starts when the user taps Play (UI / lock screen /
      // media notification). Mirrors iOS no-autoplay parity.
      // Slice 32: retry the resume restore on every batch until the
      // saved chapter actually lands in the queue. The guard latches
      // after the first successful seek so we never jump backwards
      // if more chapters arrive after the user pressed play.
      if (!player.isPlaying) {
        _restoreResumePosition(player);
        if (newChapters.length == _playableChapters.length) {
          _startResumeListener(player);
        }
      }
    }

    setState(() {
      _chaptersConverted = snapshot.chaptersCompleted ?? playable.length;
      _chaptersTotal =
          snapshot.chaptersTotal ?? _fulltext?.chapters.length ?? 0;
    });

    if (snapshot.coverUrl != null) {
      _fetchBackendCover(snapshot.coverUrl!);
    }

    if (snapshot.isTerminal) {
      _sseSubscription?.cancel();
      _sseSubscription = null;
      if (snapshot.state.toLowerCase() == 'failed') {
        setState(() {
          _isConverting = false;
          _conversionError = snapshot.error ?? 'Conversion failed';
        });
      } else {
        setState(() => _isConverting = false);
      }
    }
  }

  Future<void> _fetchBackendCover(String coverUrl) async {
    final library = ref.read(libraryStoreProvider);
    final idx = library.books.indexWhere((b) => b.id == widget.bookId);
    if (idx < 0) return;
    final book = library.books[idx];
    if (book.coverBase64 != null) return;

    try {
      final api = ref.read(apiClientProvider);
      final bytes = await api.fetchBytes(coverUrl);
      if (bytes != null && bytes.isNotEmpty && mounted) {
        book.coverBase64 = base64Encode(bytes);
        library.update(book);
      }
    } catch (_) {}
  }

  Future<void> _startLocalConversion(PythonBridge bridge) async {
    final ft = _fulltext!;
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final outDir = Directory('${docsDir.path}/audiobooks/${widget.bookId}');
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }

      final sample = ft.chapters.first.text.substring(
        0,
        ft.chapters.first.text.length.clamp(0, 500),
      );
      final lang = await bridge.detectLanguage(sample);
      final voice = _defaultVoices[lang] ?? _defaultVoices['pt']!;

      final player = ref.read(globalAudioPlayerProvider);
      _setCoverOnPlayer(player);

      for (var i = 0; i < ft.chapters.length; i++) {
        if (!mounted || !_isConverting) return;

        final ch = ft.chapters[i];
        if (ch.text.trim().isEmpty) {
          if (!mounted) return;
          setState(() => _chaptersConverted = i + 1);
          continue;
        }

        final mp3Path = '${outDir.path}/chapter_${ch.index}.mp3';
        final result = await bridge.convertChapter(
          text: ch.text,
          outputPath: mp3Path,
          voice: voice,
        );

        if (!mounted) return;

        if (result['ok'] == true) {
          final cp = ChapterProgress(
            index: ch.index,
            name: ch.name,
            status: 'completed',
            downloadUrl: 'file://$mp3Path',
            chars: ch.text.length,
            progressRatio: 1.0,
          );
          _playableChapters.add(cp);

          await player.setQueue(List.of(_playableChapters));
          // No auto-play on first segment — wait for explicit user gesture.
          if (_playableChapters.length == 1 && !player.isPlaying) {
            await _restoreResumePosition(player);
            _startResumeListener(player);
          }
        }

        setState(() => _chaptersConverted = i + 1);
      }

      if (!mounted) return;
      _markBookOffline();
      setState(() => _isConverting = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _conversionError = e.toString();
      });
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
    _resumeSaveTimer?.cancel();
    _resumeSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final resume = ref.read(resumeStoreProvider);
      final playerIdx = player.currentIndexValue ?? 0;
      final router = ResumePositionRouter(
        playableChapters: List.of(_playableChapters),
      );
      final epubIdx = router.saveValueForPlayerIndex(playerIdx);
      if (epubIdx == null) return;
      final pos = player.positionSeconds;
      resume.saveBookPosition(widget.bookId, epubIdx, pos);
    });
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
    final queueIdx =
        _resumeGuard.targetForSavedValue(saved.chapter, router);
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
    _positionSub?.cancel();
    _resumeSaveTimer?.cancel();
    _isConverting = false;
    _conversionError = null;
    _chaptersConverted = 0;
    _chaptersTotal = 0;
    _playableChapters.clear();
    _resumeGuard = ResumeRestorationGuard();
  }

  String? _buildStatusBanner(AppLocalizations t) {
    if (_conversionError != null) {
      return t.conversionFailed;
    }
    if (_isConverting && _chaptersTotal > 0) {
      return t.chaptersConverted(_chaptersConverted, _chaptersTotal);
    }
    if (_isConverting) {
      return t.startingConversion;
    }
    if (!_isConverting && _playableChapters.isNotEmpty) {
      return null;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final library = ref.watch(libraryStoreProvider);
    final book = library.books.cast().firstWhere(
      (b) => b.id == widget.bookId,
      orElse: () => null,
    );
    final bookTitle = book?.resolvedTitle ?? '';

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
          body: InstantReaderView(
            fulltext: _fulltext!,
            bookId: widget.bookId,
            coverArt: coverArt,
            statusBanner: _buildStatusBanner(t),
            player: player,
            onRequestPlay: _startConversion,
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
