import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/audio_player_service.dart';

class FullPlayerSheet extends StatelessWidget {
  final AudioPlayerService player;
  final String? bookTitle;
  final String? author;
  final String? chapterLabel;
  final Uint8List? coverArt;

  const FullPlayerSheet({
    super.key,
    required this.player,
    this.bookTitle,
    this.author,
    this.chapterLabel,
    this.coverArt,
  });

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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 24),
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Cover hero
                _coverHero(context),
                const SizedBox(height: 24),

                // Title block
                if (bookTitle != null)
                  Text(
                    bookTitle!,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (author != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    author!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).hintColor,
                        ),
                    maxLines: 1,
                  ),
                ],
                if (chapterLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    chapterLabel!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .hintColor
                              .withValues(alpha: 0.7),
                        ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                  ),
                ],
                const SizedBox(height: 28),

                // Scrubber
                _scrubber(context),
                const SizedBox(height: 20),

                // Transport row
                _transportRow(context),
                const SizedBox(height: 20),

                // Secondary row (speed + sleep)
                _secondaryRow(context),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _coverHero(BuildContext context) {
    if (coverArt != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.memory(
          coverArt!,
          width: 280,
          height: 280,
          fit: BoxFit.cover,
        ),
      );
    }
    return Container(
      width: 280,
      height: 280,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
      ),
      child: Icon(
        Icons.headphones,
        size: 80,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
      ),
    );
  }

  Widget _scrubber(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.position,
      builder: (context, posSnap) {
        final pos = (posSnap.data?.inMilliseconds ?? 0) / 1000.0;
        final dur = player.durationSeconds;
        final safeDur = dur > 0 ? dur : 1.0;
        return Column(
          children: [
            SliderTheme(
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
                    player.seek(Duration(milliseconds: (v * 1000).round())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formatTime(pos),
                      style: Theme.of(context).textTheme.bodySmall),
                  Text(_formatTime(dur),
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _transportRow(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.playing,
      builder: (context, snap) {
        final isPlaying = snap.data ?? false;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: const Icon(Icons.replay_10),
              iconSize: 32,
              onPressed: () => player.skipBackward(seconds: 15),
              tooltip: 'Skip back 15s',
            ),
            IconButton(
              icon: Icon(
                isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
              ),
              iconSize: 72,
              onPressed: player.togglePlayPause,
            ),
            IconButton(
              icon: const Icon(Icons.forward_10),
              iconSize: 32,
              onPressed: () => player.skipForward(seconds: 15),
              tooltip: 'Skip forward 15s',
            ),
          ],
        );
      },
    );
  }

  Widget _secondaryRow(BuildContext context) {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final sleepPresets = [0.0, 15 * 60.0, 30 * 60.0, 45 * 60.0, 60 * 60.0];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Speed picker
        PopupMenuButton<double>(
          onSelected: (v) => player.setSpeed(v),
          itemBuilder: (_) => speeds.map((s) {
            return PopupMenuItem(
              value: s,
              child: Text(
                '${s}x',
                style: TextStyle(
                  fontWeight: player.speed == s
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
              ),
            );
          }).toList(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
            ),
            child: Text(
              '${player.speed}x',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ),

        // Sleep timer
        StreamBuilder<double>(
          stream: player.sleepTimerStream,
          builder: (context, snap) {
            final remaining = snap.data ?? player.sleepTimerRemaining;
            return GestureDetector(
              onTap: () {
                final current = player.sleepTimerRemaining;
                final next = sleepPresets
                        .where((p) => p > current)
                        .firstOrNull ??
                    0.0;
                player.setSleepTimer(seconds: next);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.08),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.nightlight_round, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      remaining > 0
                          ? _formatTime(remaining)
                          : 'Sleep',
                      style:
                          Theme.of(context).textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
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
