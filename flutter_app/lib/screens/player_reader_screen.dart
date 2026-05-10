import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/ebook_fulltext.dart';
import '../services/api_client.dart';
import '../state/providers.dart';
import 'reader_view.dart';
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

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final job = ref.watch(jobSnapshotProvider(widget.jobId));
    final fulltext = ref.watch(fulltextProvider(widget.jobId));

    return Scaffold(
      appBar: AppBar(
        title: Text(job.valueOrNull?.bookTitle ?? widget.jobId),
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
          final controls = _PlayerControls(jobId: widget.jobId);
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
        return ReaderView(jobId: jobId, chapter: data.chapters[idx]);
      },
    );
  }
}

class _PlayerControls extends ConsumerWidget {
  const _PlayerControls({required this.jobId});
  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(jobSnapshotProvider(jobId));
    final player = ref.watch(audioPlayerProvider(jobId));
    return Padding(
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
                icon: const Icon(Icons.skip_previous),
                onPressed: () => player.raw.seekToPrevious(),
              ),
              StreamBuilder<bool>(
                stream: player.playing,
                builder: (context, snap) {
                  final playing = snap.data ?? false;
                  return IconButton(
                    iconSize: 48,
                    icon:
                        Icon(playing ? Icons.pause_circle : Icons.play_circle),
                    onPressed: () async {
                      // Lazy queue init when user first taps play.
                      final j = job.valueOrNull;
                      if (j != null && player.chapters.isEmpty) {
                        await player.setQueue(j.playableChapters);
                      }
                      if (playing) {
                        await player.pause();
                      } else {
                        await player.play();
                      }
                    },
                  );
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                onPressed: () => player.raw.seekToNext(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
