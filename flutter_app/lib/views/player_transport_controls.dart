part of 'full_player_sheet.dart';

class PlayerTransportControls extends StatelessWidget {
  const PlayerTransportControls({
    super.key,
    required this.player,
  });
  final AudioPlayerInterface player;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return StreamBuilder<bool>(
      stream: player.playing,
      builder: (context, snap) {
        final isPlaying = snap.data ?? false;
        return FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
            // Previous chapter
            Semantics(
              label: 'Previous chapter',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.skip_previous_rounded),
                iconSize: 32,
                onPressed: player.previousChapter,
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
                onPressed: () => player.skipBackward(seconds: 15),
                tooltip: 'Skip back 15s',
              ),
            ),
            const SizedBox(width: 12),
            // Play/pause
            Semantics(
              label: isPlaying ? (t?.pause ?? 'Pause') : (t?.play ?? 'Play'),
              button: true,
              child: IconButton(
                icon: Icon(
                  isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                ),
                iconSize: 72,
                onPressed: player.togglePlayPause,
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
                onPressed: () => player.skipForward(seconds: 15),
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
                onPressed: player.nextChapter,
                tooltip: 'Next chapter',
              ),
            ),
          ],
          ),
        );
      },
    );
  }

}
