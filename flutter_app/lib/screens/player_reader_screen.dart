import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import '../services/api_client.dart';
import '../services/bookmark_axis_router.dart';
import '../services/reader_chapter_resolver.dart';
import '../services/sentence_sync_coordinator.dart';
import '../services/toc_navigation_coordinator.dart';
import '../state/providers.dart';
import '../views/full_player_sheet.dart';
import '../views/reader_search_overlay.dart';
import '../views/reader_settings_sheet.dart';
import '../views/reader_theme_colors.dart';
import 'bookmarks_list_screen.dart';
import 'reader_view.dart' as scroll_reader;
import 'toc_drawer.dart';

class PlayerReaderScreen extends ConsumerStatefulWidget {
  const PlayerReaderScreen({super.key, required this.jobId});
  final String jobId;

  @override
  ConsumerState<PlayerReaderScreen> createState() =>
      _PlayerReaderScreenState();
}

class _PlayerReaderScreenState extends ConsumerState<PlayerReaderScreen> {
  int _currentChapterIndex = 0;
  bool _downloading = false;
  bool _searchVisible = false;
  bool _chromeVisible = true;
  StreamSubscription<int?>? _chapterIndexSub;
  bool _isPlaying = false;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  SentenceSyncCoordinator? _sentenceSync;

  @override
  void initState() {
    super.initState();
    // Defer subscription setup to after the first frame so that
    // ref.read is available (ConsumerState is fully mounted).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subscribeToPlayer();
    });
  }

  @override
  void didUpdateWidget(covariant PlayerReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Defense-in-depth mirror of iOS slice 43: tear down and re-bootstrap
    // when a parent feeds a new jobId without recreating the State.
    // Today all call sites push a fresh route per jobId, but keeping the
    // lifecycle invariant local prevents stale subscriptions to the old
    // audioPlayerProvider(family) from driving setState on the new job.
    // Teardown must precede resubscribe so the new bootstrap does not
    // double-subscribe for one frame.
    if (oldWidget.jobId != widget.jobId) {
      _tearDownPlayerSubscriptions();
      _currentChapterIndex = 0;
      _isPlaying = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _subscribeToPlayer();
      });
    }
  }

  void _tearDownPlayerSubscriptions() {
    _chapterIndexSub?.cancel();
    _chapterIndexSub = null;
    _playingSub?.cancel();
    _playingSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _sentenceSync = null;
  }

  void _subscribeToPlayer() {
    final player = ref.read(audioPlayerProvider(widget.jobId));

    // Track playing state so we only sync during playback.
    _playingSub = player.playing.listen((playing) {
      _isPlaying = playing;
    });

    // When the player advances to a new item, update the reader chapter.
    _chapterIndexSub = player.currentIndex.listen((playerIndex) {
      if (playerIndex == null || !_isPlaying || !mounted) return;
      final chapterIdx = player.chapterIndexForPlayerIndex(playerIndex);
      if (chapterIdx != _currentChapterIndex) {
        setState(() => _currentChapterIndex = chapterIdx);
      }
    });

    // Drive the sentence-highlight engine from the position stream so
    // ReaderView's active-sentence underline tracks the audio. Slice
    // 24 closes the silent feature gap vs iOS where this loop has
    // been live since v0.3.x.
    // First-time init only. The build() pass above is the source of
    // truth for engine identity: it ref.watches the provider and
    // re-binds the coordinator when settings change. Here we just
    // need the position subscription wired up.
    _sentenceSync ??=
        SentenceSyncCoordinator(ref.read(syncEngineProvider(widget.jobId)));
    _positionSub = player.position.listen((pos) {
      if (!mounted) return;
      _sentenceSync?.updatePosition(pos.inMilliseconds / 1000.0);
    });
  }

  @override
  void dispose() {
    _tearDownPlayerSubscriptions();
    // Always restore the system chrome when leaving the reader so
    // other screens are not left in immersive mode.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _setChromeVisible(bool visible) {
    if (_chromeVisible == visible) return;
    setState(() => _chromeVisible = visible);
    SystemChrome.setEnabledSystemUIMode(
      visible ? SystemUiMode.edgeToEdge : SystemUiMode.immersive,
    );
  }

  void _showReaderSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  void _showFullPlayer() {
    final player = ref.read(audioPlayerProvider(widget.jobId));
    // Prefer the live SSE snapshot; fall back to the one-shot fetch.
    final streamSnap = ref.read(jobStreamProvider(widget.jobId));
    final job = streamSnap.valueOrNull ??
        ref.read(jobSnapshotProvider(widget.jobId)).valueOrNull;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, controller) {
          final chapters = job?.playableChapters ?? [];
          return FullPlayerSheet(
            player: player,
            bookTitle: job?.bookTitle,
            chapterLabel: _currentChapterIndex < chapters.length
                ? chapters[_currentChapterIndex].name
                : null,
            bookId: widget.jobId,
          );
        },
      ),
    );
  }

  void _toggleBookmark() {
    final t = AppLocalizations.of(context)!;
    final store = ref.read(bookmarkStoreProvider);
    final snapshot = ref.read(jobStreamProvider(widget.jobId)).valueOrNull ??
        ref.read(jobSnapshotProvider(widget.jobId)).valueOrNull;
    final chapters = snapshot?.playableChapters ?? [];
    final chTitle = _currentChapterIndex < chapters.length
        ? chapters[_currentChapterIndex].displayTitle
        : 'Chapter ${_currentChapterIndex + 1}';

    // Bookmarks are bookId-scoped (stable across re-conversions), so
    // the persisted chapterIndex must be on the EPUB axis. Pre-slice-23
    // we were saving the playable-axis player_index which orphaned
    // bookmarks whenever the book was reconverted with a different
    // playable layout.
    final router = BookmarkAxisRouter(playableChapters: chapters);
    final existing = store
        .bookmarksForBook(widget.jobId)
        .where((b) =>
            !b.isHighlight &&
            router.matchesCurrentPosition(
              bookmark: b,
              currentPlayerIndex: _currentChapterIndex,
            ))
        .firstOrNull;
    if (existing != null) {
      store.remove(existing.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.bookmarkRemoved)),
      );
    } else {
      final epubIdx = router.saveValueForPlayerIndex(_currentChapterIndex);
      if (epubIdx == null) return;
      store.addBookmark(
        bookId: widget.jobId,
        chapterIndex: epubIdx,
        chapterTitle: chTitle,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.bookmarkAdded)),
      );
    }
  }

  void _showBookmarksList() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => BookmarksListScreen(
          bookId: widget.jobId,
          onJumpToChapter: (storedValue) {
            // Bookmarks persist the EPUB axis (slice 23); legacy
            // entries may still be on the playable axis. The router
            // tries EPUB first, then falls back, returning the
            // playable-axis position the audio queue should land on.
            final snap = ref
                    .read(jobStreamProvider(widget.jobId))
                    .valueOrNull ??
                ref.read(jobSnapshotProvider(widget.jobId)).valueOrNull;
            final router = BookmarkAxisRouter(
                playableChapters: snap?.playableChapters ?? const []);
            final playable =
                router.targetPlayerIndexForStoredValue(storedValue);
            if (playable != null) {
              setState(() => _currentChapterIndex = playable);
            }
            Navigator.pop(context);
          },
        ),
      ),
    );
  }

  Future<void> _downloadZip(JobSnapshot snapshot) async {
    final t = AppLocalizations.of(context)!;
    final zip = snapshot.outputs?.where((o) => o.isZip).firstOrNull;
    if (zip == null) return;

    setState(() => _downloading = true);
    try {
      final settings = ref.read(settingsProvider);
      final dm = ref.read(downloadManagerProvider);
      await dm.download(
        jobId: widget.jobId,
        url: '${settings.backendURL}${zip.url}',
        filename: zip.name,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.downloadComplete)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.downloadFailed)),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;

    // Merge SSE stream with the initial one-shot fetch. The stream
    // provides live updates; the FutureProvider gives us the first load.
    final initialJob = ref.watch(jobSnapshotProvider(widget.jobId));
    final streamJob = ref.watch(jobStreamProvider(widget.jobId));
    final job = streamJob.valueOrNull != null ? streamJob : initialJob;

    final fulltext = ref.watch(fulltextProvider(widget.jobId));
    final settings = ref.watch(settingsProvider);
    final bg = ReaderThemeColors.background(settings.readerTheme,
        custom: settings.readerCustomColors);

    final snapshot = job.valueOrNull;
    final hasZip = snapshot?.outputs?.any((o) => o.isZip) ?? false;

    // Re-prime the sentence-sync engine whenever the EPUB text or the
    // playable cursor changes. `loadIfChanged` is idempotent on
    // identical inputs, so calling it from build is safe. Watching
    // syncEngineProvider (not ref.read) is what catches a settings
    // change that rebuilds the engine — the coordinator then rebinds
    // and reloads instead of writing into a disposed stream.
    final ft = fulltext.valueOrNull;
    if (ft != null) {
      final engine = ref.watch(syncEngineProvider(widget.jobId));
      _sentenceSync ??= SentenceSyncCoordinator(engine);
      _sentenceSync!.rebindIfEngineChanged(engine);
      _sentenceSync!.loadIfChanged(
        fulltext: ft,
        playableChapters: snapshot?.playableChapters ?? const [],
        playableIndex: _currentChapterIndex,
      );
    }

    return Scaffold(
      backgroundColor: bg,
      appBar: _chromeVisible
          ? AppBar(
              title: Text(snapshot?.bookTitle ?? widget.jobId),
              backgroundColor: bg,
              actions: [
                if (hasZip)
                  _downloading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.download),
                          onPressed: snapshot != null
                              ? () => _downloadZip(snapshot)
                              : null,
                          tooltip: t.downloadAll,
                        ),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () =>
                      setState(() => _searchVisible = !_searchVisible),
                  tooltip: t.searchInBook,
                ),
                Consumer(
                  builder: (context, ref, _) {
                    final store = ref.watch(bookmarkStoreProvider);
                    // Mirror the dual-axis check used by `_toggleBookmark`
                    // so the bookmark icon stays accurate for both modern
                    // EPUB-axis saves and legacy playable-axis entries.
                    final router = BookmarkAxisRouter(
                        playableChapters:
                            snapshot?.playableChapters ?? const []);
                    final hasIt = store
                        .bookmarksForBook(widget.jobId)
                        .any((b) =>
                            !b.isHighlight &&
                            router.matchesCurrentPosition(
                              bookmark: b,
                              currentPlayerIndex: _currentChapterIndex,
                            ));
                    return IconButton(
                      icon: Icon(
                          hasIt ? Icons.bookmark : Icons.bookmark_border),
                      onPressed: _toggleBookmark,
                      tooltip: t.addBookmark,
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.bookmarks_outlined),
                  onPressed: _showBookmarksList,
                  tooltip: t.bookmarksTitle,
                ),
                IconButton(
                  icon: const Icon(Icons.text_format),
                  onPressed: _showReaderSettings,
                  tooltip: t.readerSettings,
                ),
              ],
            )
          : null,
      drawer: TocDrawer(
        fulltext: fulltext.valueOrNull,
        snapshot: snapshot,
        currentIndex: TocNavigationCoordinator.highlightEpubIndex(
          currentPlayableIndex: _currentChapterIndex,
          playableChapters: snapshot?.playableChapters ?? const [],
        ),
        onJump: (epubIdx) {
          final playable =
              TocNavigationCoordinator.targetPlayableIndexForTocTap(
            tappedEpubIndex: epubIdx,
            playableChapters: snapshot?.playableChapters ?? const [],
          );
          if (playable != null) {
            setState(() => _currentChapterIndex = playable);
          }
        },
      ),
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth > 700;
              final reader = _Reader(
                fulltext: fulltext,
                chapterIndex: _currentChapterIndex,
                playableChapters: snapshot?.playableChapters ?? const [],
                jobId: widget.jobId,
                t: t,
                onCenterTap: () => _setChromeVisible(!_chromeVisible),
              );
              final controls = _PlayerControls(
                jobId: widget.jobId,
                snapshot: snapshot,
                onExpandPlayer: _showFullPlayer,
              );
              if (wide) {
                return Row(children: [
                  Expanded(child: reader),
                  const VerticalDivider(width: 1),
                  if (_chromeVisible)
                    SizedBox(width: 320, child: controls),
                ]);
              }
              return Column(children: [
                Expanded(child: reader),
                if (_chromeVisible) ...[
                  const Divider(height: 1),
                  controls,
                ],
              ]);
            },
          ),
          if (_searchVisible)
            ReaderSearchOverlay(
              chapters: fulltext.valueOrNull?.chapters ?? const [],
              onJumpToChapter: (epubIdx) {
                // Search overlay emits FulltextChapter.index (EPUB axis).
                // Translate to the playable axis the rest of the screen
                // tracks. Non-playable matches leave the audio position
                // unchanged.
                final playable =
                    TocNavigationCoordinator.targetPlayableIndexForTocTap(
                  tappedEpubIndex: epubIdx,
                  playableChapters: snapshot?.playableChapters ?? const [],
                );
                setState(() {
                  if (playable != null) _currentChapterIndex = playable;
                  _searchVisible = false;
                });
              },
              onClose: () => setState(() => _searchVisible = false),
            ),
        ],
      ),
    );
  }
}

class _Reader extends StatelessWidget {
  const _Reader({
    required this.fulltext,
    required this.chapterIndex,
    required this.playableChapters,
    required this.jobId,
    required this.t,
    this.onCenterTap,
  });

  final AsyncValue<EbookFulltext> fulltext;
  final int chapterIndex;
  final List<ChapterProgress> playableChapters;
  final String jobId;
  final AppLocalizations t;
  final VoidCallback? onCenterTap;

  @override
  Widget build(BuildContext context) {
    return fulltext.when(
      loading: () => Center(child: Text(t.loadingFulltext)),
      error: (e, _) {
        if (e is FulltextGone) {
          return Center(child: Text(t.fulltextGone));
        }
        if (e is FulltextEmpty) {
          return Center(child: Text(t.fulltextEmpty));
        }
        return Center(child: Text(t.errorWithMessage('$e')));
      },
      data: (data) {
        if (data.chapters.isEmpty) {
          return Center(child: Text(t.fulltextEmpty));
        }
        final resolved = ReaderChapterResolver.resolveFulltextChapter(
          fulltext: data,
          playableChapters: playableChapters,
          playableIndex: chapterIndex,
        );
        final chapter = resolved ??
            data.chapters[chapterIndex.clamp(0, data.chapters.length - 1)];
        return scroll_reader.ReaderView(
          jobId: jobId,
          chapter: chapter,
          onCenterTap: onCenterTap,
        );
      },
    );
  }
}

class _PlayerControls extends ConsumerWidget {
  const _PlayerControls({
    required this.jobId,
    this.snapshot,
    this.onExpandPlayer,
  });
  final String jobId;
  final JobSnapshot? snapshot;
  final VoidCallback? onExpandPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final player = ref.watch(audioPlayerProvider(jobId));
    final snap = snapshot;

    // Build progress string from live snapshot.
    String statusText;
    if (snap == null) {
      statusText = t.startingConversion;
    } else {
      final total = snap.chaptersTotal ?? 0;
      final done = snap.chaptersCompleted ?? 0;
      if (total > 0) {
        statusText =
            '${snap.state} • ${t.chaptersConverted(done, total)}';
      } else {
        statusText =
            '${snap.state} • ${(snap.progressPercent ?? 0).toStringAsFixed(1)}%';
      }
    }

    return GestureDetector(
      onTap: onExpandPlayer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(statusText),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StreamBuilder<bool>(
                  stream: player.playing,
                  builder: (context, snap) {
                    final playing = snap.data ?? false;
                    return IconButton(
                      iconSize: 48,
                      icon: Icon(
                          playing ? Icons.pause_circle : Icons.play_circle),
                      onPressed: () async {
                        final j = snapshot;
                        if (j != null && player.chapters.isEmpty) {
                          await player.setQueue(j.playableChapters);
                        }
                        player.togglePlayPause();
                      },
                    );
                  },
                ),
                const SizedBox(width: 16),
                IconButton(
                  icon: const Icon(Icons.forward_30),
                  onPressed: () => player.skipForward(seconds: 30),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
