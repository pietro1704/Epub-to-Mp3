import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import '../services/api_client.dart';
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
  StreamSubscription<int?>? _chapterIndexSub;
  bool _isPlaying = false;
  StreamSubscription<bool>? _playingSub;

  @override
  void initState() {
    super.initState();
    // Defer subscription setup to after the first frame so that
    // ref.read is available (ConsumerState is fully mounted).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subscribeToPlayer();
    });
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
  }

  @override
  void dispose() {
    _chapterIndexSub?.cancel();
    _playingSub?.cancel();
    super.dispose();
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

    if (store.hasBookmark(widget.jobId, _currentChapterIndex)) {
      final existing = store
          .bookmarksForChapter(widget.jobId, _currentChapterIndex)
          .where((b) => !b.isHighlight)
          .firstOrNull;
      if (existing != null) {
        store.remove(existing.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.bookmarkRemoved)),
        );
      }
    } else {
      store.addBookmark(
        bookId: widget.jobId,
        chapterIndex: _currentChapterIndex,
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
          onJumpToChapter: (idx) {
            setState(() => _currentChapterIndex = idx);
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

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
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
                      child: CircularProgressIndicator(strokeWidth: 2),
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
            onPressed: () => setState(() => _searchVisible = !_searchVisible),
            tooltip: t.searchInBook,
          ),
          Consumer(
            builder: (context, ref, _) {
              final store = ref.watch(bookmarkStoreProvider);
              final hasIt = store.hasBookmark(
                  widget.jobId, _currentChapterIndex);
              return IconButton(
                icon: Icon(hasIt ? Icons.bookmark : Icons.bookmark_border),
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
      ),
      drawer: TocDrawer(
        fulltext: fulltext.valueOrNull,
        snapshot: snapshot,
        currentIndex: _currentChapterIndex,
        onJump: (idx) => setState(() => _currentChapterIndex = idx),
      ),
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth > 700;
              final reader = _Reader(
                fulltext: fulltext,
                chapterIndex: _currentChapterIndex,
                jobId: widget.jobId,
                t: t,
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
                  SizedBox(width: 320, child: controls),
                ]);
              }
              return Column(children: [
                Expanded(child: reader),
                const Divider(height: 1),
                controls,
              ]);
            },
          ),
          if (_searchVisible)
            ReaderSearchOverlay(
              chapters: fulltext.valueOrNull?.chapters ?? const [],
              onJumpToChapter: (idx) {
                setState(() {
                  _currentChapterIndex = idx;
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
    required this.jobId,
    required this.t,
  });

  final AsyncValue<EbookFulltext> fulltext;
  final int chapterIndex;
  final String jobId;
  final AppLocalizations t;

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
        return Center(child: Text('Error: $e'));
      },
      data: (data) {
        if (data.chapters.isEmpty) {
          return Center(child: Text(t.fulltextEmpty));
        }
        final idx = chapterIndex.clamp(0, data.chapters.length - 1);
        return scroll_reader.ReaderView(
          jobId: jobId,
          chapter: data.chapters[idx],
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
