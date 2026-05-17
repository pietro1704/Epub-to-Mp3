import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../services/audio_player_service.dart';
import '../state/providers.dart';
import '../screens/library_screen.dart';

class FullPlayerSheet extends ConsumerStatefulWidget {
  final AudioPlayerService player;
  final String? bookTitle;
  final String? author;
  final String? chapterLabel;
  final Uint8List? coverArt;
  final String? bookId;

  const FullPlayerSheet({
    super.key,
    required this.player,
    this.bookTitle,
    this.author,
    this.chapterLabel,
    this.coverArt,
    this.bookId,
  });

  @override
  ConsumerState<FullPlayerSheet> createState() => _FullPlayerSheetState();
}

class _FullPlayerSheetState extends ConsumerState<FullPlayerSheet> {
  bool _downloading = false;
  String? _downloadStatus;

  Future<void> _downloadAll() async {
    if (_downloading) return;
    final chapters = widget.player.chapters;
    if (chapters.isEmpty) return;

    final dm = ref.read(downloadManagerProvider);
    final settings = ref.read(settingsProvider);
    final base = settings.backendURL.trim();

    setState(() {
      _downloading = true;
      _downloadStatus = '0/${chapters.length}';
    });

    var completed = 0;
    for (final ch in chapters) {
      final url = ch.downloadUrl;
      if (url == null || url.startsWith('file:')) {
        completed++;
        continue;
      }
      final fullUrl = url.startsWith('http')
          ? url
          : '${base.endsWith('/') ? base.substring(0, base.length - 1) : base}$url';
      final name = 'chapter_${ch.index}.mp3';
      final jobId = widget.bookId ?? 'unknown';
      try {
        await dm.download(jobId: jobId, url: fullUrl, filename: name);
      } catch (_) {}
      completed++;
      if (!mounted) return;
      setState(() => _downloadStatus = '$completed/${chapters.length}');
    }

    if (!mounted) return;

    // Mark book as offline
    if (widget.bookId != null) {
      final library = ref.read(libraryStoreProvider);
      final idx = library.books.indexWhere((b) => b.id == widget.bookId);
      if (idx >= 0) {
        final book = library.books[idx];
        book.cachedOffline = true;
        library.update(book);
      }
    }

    setState(() {
      _downloading = false;
      _downloadStatus = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(child: _coverHero(context)),
                    const SizedBox(height: 20),
                    if (widget.bookTitle != null)
                      Text(
                        widget.bookTitle!,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (widget.author != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.author!,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).hintColor,
                            ),
                        maxLines: 1,
                      ),
                    ],
                    if (widget.chapterLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.chapterLabel!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .hintColor
                                  .withValues(alpha: 0.7),
                            ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                      ),
                    ],
                  ],
                ),
              ),
              _scrubber(context),
              const SizedBox(height: 20),
              _transportRow(context),
              const SizedBox(height: 20),
              _secondaryRow(context),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverHero(BuildContext context) {
    final t = AppLocalizations.of(context);
    if (widget.coverArt != null) {
      return Semantics(
        label: t?.albumArt ?? 'Album art',
        image: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: AspectRatio(
            aspectRatio: 2.0 / 3.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Image.memory(
                widget.coverArt!,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      );
    }
    // Decorative placeholder — hide from screen readers.
    return ExcludeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: AspectRatio(
          aspectRatio: 2.0 / 3.0,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
            ),
            child: Icon(
              Icons.headphones,
              size: 80,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  Widget _scrubber(BuildContext context) {
    final t = AppLocalizations.of(context);
    return StreamBuilder<Duration>(
      stream: widget.player.position,
      builder: (context, posSnap) {
        final pos = (posSnap.data?.inMilliseconds ?? 0) / 1000.0;
        final dur = widget.player.durationSeconds;
        final safeDur = dur > 0 ? dur : 1.0;
        return Column(
          children: [
            Semantics(
              label: t?.playbackPosition ?? 'Playback position',
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 4,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor:
                      Theme.of(context).colorScheme.onSurface,
                  inactiveTrackColor:
                      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.2),
                  thumbColor:
                      Theme.of(context).colorScheme.onSurface,
                ),
                child: Slider(
                  value: pos.clamp(0, safeDur),
                  max: safeDur,
                  onChanged: (v) =>
                      widget.player.seek(Duration(milliseconds: (v * 1000).round())),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ExcludeSemantics(
                    child: Text(_formatTime(pos),
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                  ExcludeSemantics(
                    child: Text(
                        '-${_formatTime((dur - pos) / widget.player.speed)}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _transportRow(BuildContext context) {
    final t = AppLocalizations.of(context);
    return StreamBuilder<bool>(
      stream: widget.player.playing,
      builder: (context, snap) {
        final isPlaying = snap.data ?? false;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Previous chapter
            Semantics(
              label: 'Previous chapter',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.skip_previous_rounded),
                iconSize: 32,
                onPressed: widget.player.previousChapter,
                tooltip: 'Previous chapter',
              ),
            ),
            const SizedBox(width: 12),
            // Skip -15s
            Semantics(
              label: 'Skip back 15 seconds',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.replay_10),
                iconSize: 32,
                onPressed: () => widget.player.skipBackward(seconds: 15),
                tooltip: 'Skip back 15s',
              ),
            ),
            const SizedBox(width: 12),
            // Play/pause
            Semantics(
              label: isPlaying
                  ? (t?.pause ?? 'Pause')
                  : (t?.play ?? 'Play'),
              button: true,
              child: IconButton(
                icon: Icon(
                  isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                ),
                iconSize: 72,
                onPressed: widget.player.togglePlayPause,
              ),
            ),
            const SizedBox(width: 12),
            // Skip +15s
            Semantics(
              label: 'Skip forward 15 seconds',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.forward_10),
                iconSize: 32,
                onPressed: () => widget.player.skipForward(seconds: 15),
                tooltip: 'Skip forward 15s',
              ),
            ),
            const SizedBox(width: 12),
            // Next chapter
            Semantics(
              label: 'Next chapter',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.skip_next_rounded),
                iconSize: 32,
                onPressed: widget.player.nextChapter,
                tooltip: 'Next chapter',
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _secondaryRow(BuildContext context) {
    final t = AppLocalizations.of(context);
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final sleepPresets = [0.0, 15 * 60.0, 30 * 60.0, 45 * 60.0, 60 * 60.0];
    final hasChapters = widget.player.chapters.isNotEmpty;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Speed picker
        Semantics(
          label: '${t?.playbackSpeed ?? 'Playback speed'}: ${widget.player.speed}x',
          button: true,
          child: PopupMenuButton<double>(
            onSelected: (v) => widget.player.setSpeed(v),
            itemBuilder: (_) => speeds.map((s) {
              return PopupMenuItem(
                value: s,
                child: Text(
                  '${s}x',
                  style: TextStyle(
                    fontWeight: widget.player.speed == s
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              );
            }).toList(),
            child: _pill(context, '${widget.player.speed}x'),
          ),
        ),

        // Download button
        if (hasChapters)
          GestureDetector(
            onTap: _downloading ? null : _downloadAll,
            child: _pill(
              context,
              _downloading
                  ? _downloadStatus ?? '...'
                  : t?.saveForOffline ?? 'Save',
              icon: _downloading
                  ? Icons.downloading
                  : Icons.download_rounded,
            ),
          ),

        // Sleep timer
        StreamBuilder<double>(
          stream: widget.player.sleepTimerStream,
          builder: (context, snap) {
            final remaining = snap.data ?? widget.player.sleepTimerRemaining;
            return Semantics(
              label: t?.sleepTimer ?? 'Sleep timer',
              button: true,
              child: GestureDetector(
                onTap: () {
                  final current = widget.player.sleepTimerRemaining;
                  final next = sleepPresets
                          .where((p) => p > current)
                          .firstOrNull ??
                      0.0;
                  widget.player.setSleepTimer(seconds: next);
                },
                child: _pill(
                  context,
                  remaining > 0 ? _formatTime(remaining) : 'Sleep',
                  icon: Icons.nightlight_round,
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _pill(BuildContext context, String label, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  String _formatTime(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '0:00';
    final total = seconds.toInt();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
