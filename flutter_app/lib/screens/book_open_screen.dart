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
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import '../services/audio_player_service.dart';
import '../services/python_bridge.dart';
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

  // Conversion state
  String? _jobId;
  bool _isConverting = false;
  String? _conversionError;
  JobSnapshot? _latestSnapshot;
  StreamSubscription<JobSnapshot>? _sseSub;

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
    _sseSub?.cancel();
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

  /// Upload the EPUB to the backend, start conversion, and begin
  /// listening to the SSE stream for progress updates.
  Future<void> _startConversion() async {
    if (_isConverting || _jobId != null) return;

    final library = ref.read(libraryStoreProvider);
    final book = library.books.cast().firstWhere(
          (b) => b.id == widget.bookId,
          orElse: () => null,
        );
    if (book == null) return;

    setState(() {
      _isConverting = true;
      _conversionError = null;
    });

    try {
      final api = ref.read(apiClientProvider);
      final jobId = await api.uploadAndConvert(book.filePath);
      if (!mounted) return;

      setState(() {
        _jobId = jobId;
      });

      // Mark this book as currently playing.
      ref.read(currentlyPlayingBookIdProvider.notifier).state = widget.bookId;

      // Start listening to SSE for live progress.
      _listenToJobStream(jobId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConverting = false;
        _conversionError = e.toString();
      });
    }
  }

  void _listenToJobStream(String jobId) {
    final api = ref.read(apiClientProvider);
    _sseSub?.cancel();
    _sseSub = api.jobStream(jobId).listen(
      (snapshot) {
        if (!mounted) return;
        setState(() {
          _latestSnapshot = snapshot;
        });

        // Auto-enqueue playable chapters as they arrive.
        _enqueueNewChapters(snapshot);

        // Stop listening when job reaches terminal state.
        if (snapshot.isTerminal) {
          _sseSub?.cancel();
          _sseSub = null;
          setState(() => _isConverting = false);
        }
      },
      onError: (_) {
        // SSE connection lost — fall back to polling.
        if (!mounted) return;
        _pollUntilTerminal(jobId);
      },
      onDone: () {
        // Stream ended normally (server closed).
        if (!mounted) return;
        if (_latestSnapshot != null && !_latestSnapshot!.isTerminal) {
          _pollUntilTerminal(jobId);
        } else {
          setState(() => _isConverting = false);
        }
      },
    );
  }

  /// Simple poll fallback when SSE drops.
  Future<void> _pollUntilTerminal(String jobId) async {
    final api = ref.read(apiClientProvider);
    while (mounted) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted) return;
      try {
        final snap = await api.fetchJob(jobId);
        if (!mounted) return;
        setState(() => _latestSnapshot = snap);
        _enqueueNewChapters(snap);
        if (snap.isTerminal) {
          setState(() => _isConverting = false);
          return;
        }
      } catch (_) {
        // Network error — keep polling.
      }
    }
  }

  int _lastEnqueuedIndex = -1;

  void _enqueueNewChapters(JobSnapshot snapshot) {
    final player =
        ref.read(globalAudioPlayerProvider) as AudioPlayerService;
    final playable = snapshot.playableChapters;

    if (playable.isEmpty) return;

    // On first playable chapter, set the full queue so chapter navigation
    // works. Subsequent chapters are enqueued incrementally.
    if (_lastEnqueuedIndex < 0 && playable.isNotEmpty) {
      player.setQueue(playable).then((_) {
        if (mounted && !player.raw.playing) {
          player.play();
        }
      });
      _lastEnqueuedIndex = playable.length - 1;
      return;
    }

    // Enqueue any newly completed chapters beyond what we already queued.
    if (playable.length > _lastEnqueuedIndex + 1) {
      // Re-set full queue so all chapters are available.
      player.setQueue(playable);
      _lastEnqueuedIndex = playable.length - 1;
    }
  }

  void _cancelConversion() {
    _sseSub?.cancel();
    _sseSub = null;
    _jobId = null;
    _isConverting = false;
    _conversionError = null;
    _latestSnapshot = null;
    _lastEnqueuedIndex = -1;
  }

  String? _buildStatusBanner(AppLocalizations t) {
    if (_conversionError != null) {
      return t.conversionFailed;
    }
    if (_isConverting && _latestSnapshot == null) {
      return t.startingConversion;
    }
    final snap = _latestSnapshot;
    if (snap == null) return null;
    if (snap.state.toLowerCase() == 'failed') {
      return snap.error ?? t.conversionFailed;
    }
    final total = snap.chaptersTotal ?? 0;
    final done = snap.chaptersCompleted ?? 0;
    if (total > 0) {
      return t.chaptersConverted(done, total);
    }
    if (_isConverting) {
      return t.generatingAudio;
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
                Icon(Icons.error_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text(t.parsingFailed,
                    style: Theme.of(context).textTheme.titleMedium),
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
        final player = _jobId != null
            ? ref.read(globalAudioPlayerProvider) as AudioPlayerService
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
