// Persistent mini player bar shown at the bottom of all tabs, above the
// NavigationBar. Mirrors iOS MiniPlayerBar.
//
// Layout: [cover 44x44] [title / chapter] [spacer] [play/pause] [skip +15s]
// 2pt progress bar at top (orange during conversion, accent during playback).
// Tap opens FullPlayerSheet. Hidden when nothing is playing.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_player_service.dart';
import '../state/providers.dart';
import 'full_player_sheet.dart';
import '../screens/library_screen.dart';

class MiniPlayerBar extends ConsumerWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playingBookId = ref.watch(currentlyPlayingBookIdProvider);
    if (playingBookId == null) return const SizedBox.shrink();

    final library = ref.watch(libraryStoreProvider);
    final book = library.books.cast().firstWhere(
          (b) => b.id == playingBookId,
          orElse: () => null,
        );
    if (book == null) return const SizedBox.shrink();

    final player = ref.watch(globalAudioPlayerProvider);
    final cs = Theme.of(context).colorScheme;
    final Uint8List? coverArt = _decodeCover(book.coverBase64);

    return GestureDetector(
      onTap: () => _showFullPlayer(context, player, book.resolvedTitle,
          book.author, coverArt, playingBookId),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          border: Border(
            top: BorderSide(color: cs.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 2pt progress bar
            StreamBuilder<Duration>(
              stream: player.position,
              builder: (context, snap) {
                final pos =
                    (snap.data?.inMilliseconds ?? 0) / 1000.0;
                final dur = player.durationSeconds;
                final fraction =
                    dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
                return LinearProgressIndicator(
                  value: fraction,
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  color: cs.primary,
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  // Cover art 44x44 — decorative, excluded from semantics
                  ExcludeSemantics(
                    child: coverArt != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(
                              coverArt,
                              width: 44,
                              height: 44,
                              fit: BoxFit.cover,
                            ),
                          )
                        : Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              color: cs.primaryContainer,
                            ),
                            child: Icon(Icons.headphones,
                                color: cs.onPrimaryContainer, size: 22),
                          ),
                  ),
                  const SizedBox(width: 10),

                  // Title / chapter info — announced by TalkBack
                  Expanded(
                    child: Semantics(
                      label: book.resolvedTitle,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            book.resolvedTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (book.author != null)
                            Text(
                              book.author!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ),

                  // Play/pause
                  StreamBuilder<bool>(
                    stream: player.playing,
                    builder: (context, snap) {
                      final isPlaying = snap.data ?? false;
                      return Semantics(
                        label: isPlaying ? 'Pause' : 'Play',
                        button: true,
                        child: IconButton(
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 28,
                          ),
                          onPressed: player.togglePlayPause,
                        ),
                      );
                    },
                  ),

                  // Skip +15s
                  IconButton(
                    icon: const Icon(Icons.forward_10, size: 24),
                    onPressed: () => player.skipForward(seconds: 15),
                    tooltip: 'Skip forward 15 seconds',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFullPlayer(
    BuildContext context,
    AudioPlayerInterface player,
    String? bookTitle,
    String? author,
    Uint8List? coverArt,
    String? bookId,
  ) {
    if (player is! AudioPlayerService) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, controller) => FullPlayerSheet(
          player: player,
          bookTitle: bookTitle,
          author: author,
          coverArt: coverArt,
          bookId: bookId,
        ),
      ),
    );
  }

  static Uint8List? _decodeCover(String? base64Str) {
    if (base64Str == null) return null;
    try {
      return base64Decode(base64Str);
    } catch (_) {
      return null;
    }
  }
}
