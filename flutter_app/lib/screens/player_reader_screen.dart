import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../services/api_client.dart';
import '../state/providers.dart';
import '../views/full_player_sheet.dart';
import '../views/reader_settings_sheet.dart';
import '../views/reader_theme_colors.dart';
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
    final job = ref.read(jobSnapshotProvider(widget.jobId)).valueOrNull;
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
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final job = ref.watch(jobSnapshotProvider(widget.jobId));
    final fulltext = ref.watch(fulltextProvider(widget.jobId));
    final settings = ref.watch(settingsProvider);
    final bg = ReaderThemeColors.background(settings.readerTheme,
        custom: settings.readerCustomColors);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: Text(job.valueOrNull?.bookTitle ?? widget.jobId),
        backgroundColor: bg,
        actions: [
          IconButton(
            icon: const Icon(Icons.text_format),
            onPressed: _showReaderSettings,
            tooltip: 'Reader settings',
          ),
        ],
      ),
      drawer: TocDrawer(
        fulltext: fulltext.valueOrNull,
        snapshot: job.valueOrNull,
        currentIndex: _currentChapterIndex,
        onJump: (idx) => setState(() => _currentChapterIndex = idx),
      ),
      body: LayoutBuilder(
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
    this.onExpandPlayer,
  });
  final String jobId;
  final VoidCallback? onExpandPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(jobSnapshotProvider(jobId));
    final player = ref.watch(audioPlayerProvider(jobId));
    return GestureDetector(
      onTap: onExpandPlayer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            job.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Error: $e'),
              data: (snap) => Text(
                '${snap.state} • ${(snap.progressPercent ?? 0).toStringAsFixed(1)}%',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(Icons.replay_10),
                  onPressed: () => player.skipBackward(seconds: 15),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () => player.previousChapter(),
                ),
                StreamBuilder<bool>(
                  stream: player.playing,
                  builder: (context, snap) {
                    final playing = snap.data ?? false;
                    return IconButton(
                      iconSize: 48,
                      icon: Icon(
                          playing ? Icons.pause_circle : Icons.play_circle),
                      onPressed: () async {
                        final j = job.valueOrNull;
                        if (j != null && player.chapters.isEmpty) {
                          await player.setQueue(j.playableChapters);
                        }
                        player.togglePlayPause();
                      },
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => player.nextChapter(),
                ),
                IconButton(
                  icon: const Icon(Icons.forward_10),
                  onPressed: () => player.skipForward(seconds: 15),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
