// Persistent mini player bar shown at the bottom of all tabs, above the
// NavigationBar. Mirrors iOS MiniPlayerBar.
//
// Layout: [cover 44x44] [chapter / book] [spacer] [play/pause] [skip +15s].
// Tap opens FullPlayerSheet. Hidden when nothing is playing.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/audio_player_service.dart';
import '../services/background_audio_handler.dart' as background_audio;
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
    final backgroundHandler = ref.watch(backgroundAudioHandlerProvider);
    final cs = Theme.of(context).colorScheme;
    final Uint8List? coverArt = _decodeCover(book.coverBase64);

    return GestureDetector(
      onTap: () => _showFullPlayer(
        context,
        player,
        book.resolvedTitle,
        book.author,
        coverArt,
        playingBookId,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                          fit: BoxFit.contain,
                        ),
                      )
                    : Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          color: cs.primaryContainer,
                        ),
                        child: Icon(
                          Icons.headphones,
                          color: cs.onPrimaryContainer,
                          size: 22,
                        ),
                      ),
              ),
              const SizedBox(width: 10),

              // The audible chapter is primary; the book is secondary.
              Expanded(
                child: StreamBuilder<int?>(
                  stream: player.currentIndex,
                  initialData: player.currentIndexValue,
                  builder: (context, snapshot) {
                    final playerIndex = snapshot.data;
                    final chapterIndex = playerIndex == null
                        ? null
                        : player.chapterIndexForPlayerIndex(playerIndex);
                    final chapter =
                        chapterIndex != null &&
                            chapterIndex >= 0 &&
                            chapterIndex < player.chapters.length
                        ? player.chapters[chapterIndex]
                        : null;
                    final chapterTitle =
                        chapter?.displayTitle ?? book.resolvedTitle;
                    if (backgroundHandler != null) {
                      unawaited(
                        backgroundHandler.setMetadata(
                          background_audio.BackgroundAudioMetadata(
                            bookId: book.id,
                            bookTitle: book.resolvedTitle,
                            author: book.author,
                            chapterTitle: chapter?.displayTitle,
                            chapterIndex: chapter?.index,
                          ),
                        ),
                      );
                    }
                    return Semantics(
                      label: '$chapterTitle, ${book.resolvedTitle}',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            book.resolvedTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

              // Skip -15s
              IconButton(
                icon: const Icon(Icons.replay_10, size: 24),
                onPressed: () => player.skipBackward(seconds: 15),
                tooltip: 'Skip back 15 seconds',
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

              // Speed picker — compact label
              PopupMenuButton<double>(
                onSelected: (v) => player.setSpeed(v),
                tooltip: 'Playback speed',
                padding: EdgeInsets.zero,
                itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
                    .map(
                      (s) => PopupMenuItem(
                        value: s,
                        child: Text(
                          '${s}x',
                          style: TextStyle(
                            fontWeight: player.speed == s
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                child: Semantics(
                  label: 'Speed ${player.speed}x',
                  button: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      '${player.speed}x',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),

              // Sleep timer — tap cycles presets
              StreamBuilder<double>(
                stream: player.sleepTimerStream,
                builder: (context, snap) {
                  final remaining = snap.data ?? player.sleepTimerRemaining;
                  return Semantics(
                    label: remaining > 0
                        ? 'Sleep timer active'
                        : 'Sleep timer off',
                    button: true,
                    child: IconButton(
                      icon: Icon(
                        remaining > 0
                            ? Icons.nightlight
                            : Icons.nightlight_outlined,
                        size: 20,
                      ),
                      onPressed: () {
                        const presets = [0.0, 900.0, 1800.0, 2700.0, 3600.0];
                        final current = player.sleepTimerRemaining;
                        final next =
                            presets.where((p) => p > current).firstOrNull ??
                            0.0;
                        player.setSleepTimer(seconds: next);
                      },
                      tooltip: 'Sleep timer',
                    ),
                  );
                },
              ),
            ],
          ),
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
