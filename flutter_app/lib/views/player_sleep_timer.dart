part of 'full_player_sheet.dart';

class PlayerSleepTimer extends StatelessWidget {
  const PlayerSleepTimer({
    super.key,
    required this.player,
    required this.pill,
    required this.formatTime,
  });

  final AudioPlayerInterface player;
  final Widget Function(BuildContext, String, {IconData? icon}) pill;
  final String Function(double) formatTime;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final sleepPresets = [0.0, 15 * 60.0, 30 * 60.0, 45 * 60.0, 60 * 60.0];
    return StreamBuilder<double>(
      stream: player.sleepTimerStream,
      builder: (context, snap) {
        final remaining = snap.data ?? player.sleepTimerRemaining;
        return Semantics(
          label: t?.sleepTimer ?? 'Sleep timer',
          button: true,
          child: GestureDetector(
            onTap: () {
              final current = player.sleepTimerRemaining;
              final next =
                  sleepPresets.where((p) => p > current).firstOrNull ?? 0.0;
              player.setSleepTimer(seconds: next);
            },
            child: pill(
              context,
              remaining > 0 ? formatTime(remaining) : 'Sleep',
              icon: Icons.nightlight_round,
            ),
          ),
        );
      },
    );
  }
}
