part of 'settings_screen.dart';

class PlaybackPreferences extends ConsumerWidget {
  const PlaybackPreferences({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Playback ──
        _SectionHeader(t.playbackSection),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.speed, color: cs.onSurfaceVariant),
                title: Text(t.audioRateLabel),
                subtitle: Slider(
                  value: settings.audioRate,
                  min: 0.5,
                  max: 2.0,
                  divisions: 30,
                  label: '${settings.audioRate.toStringAsFixed(2)}x',
                  onChanged: notifier.setAudioRate,
                ),
                trailing: Text(
                  '${settings.audioRate.toStringAsFixed(2)}x',
                  style: tt.bodyMedium?.copyWith(
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: Icon(
                  Icons.timer_outlined,
                  color: cs.onSurfaceVariant,
                ),
                title: Text(t.wpmLabel),
                subtitle: Slider(
                  value: settings.wpm.toDouble(),
                  min: 100,
                  max: 320,
                  divisions: 22,
                  label: '${settings.wpm}',
                  onChanged: (v) => notifier.setWpm(v.round()),
                ),
                trailing: Text(
                  '${settings.wpm}',
                  style: tt.bodyMedium?.copyWith(
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

      ],
    );
  }
}
