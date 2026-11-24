part of 'settings_screen.dart';

/// The two fallbacks of narration: the installed system voice and online (Edge) speech. Which voice
/// plays each language is chosen per language, on the language's page; the global primary and
/// reserve menus no longer exist (`migrateGlobalVoiceToLanguageChoices` moved what they held).
class VoiceSelectionSettings extends ConsumerWidget {
  const VoiceSelectionSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final catalog = ref.watch(ttsCatalogProvider).asData?.value;
    final recommended =
        catalog?.recommendedPreferences ?? const TtsPreferences.appDefaults();
    final preferences = settings.configuredTtsPreferences ?? recommended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(t.modelsFallbackSection),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                title: Text(t.ttsAllowOnlineSecondary),
                subtitle: Text(t.ttsOnlineSecondaryDescription),
                value: preferences.allowOnlineFallback,
                onChanged: (value) {
                  // Edge as the primary voice needs this consent: revoking it
                  // moves the primary to the default Piper at once.
                  final prefs = !value && preferences.primary.engine == 'edge'
                      ? preferences.withPrimary(TtsSelection.automaticPiper)
                      : preferences;
                  notifier.setTtsPreferences(
                    TtsPreferences(
                      primary: prefs.primary,
                      secondary: !value && prefs.secondary?.engine == 'edge'
                          ? null
                          : prefs.secondary,
                      allowOnlineFallback: value,
                      policyVersion: prefs.policyVersion,
                      footnoteNarration: prefs.footnoteNarration,
                    ),
                  );
                },
              ),
              SwitchListTile(
                key: const ValueKey('tts-automatic-system-fallback'),
                title: Text(t.ttsAutomaticSystemFallback),
                subtitle: Text(t.ttsAutomaticSystemFallbackDescription),
                value: preferences.allowAutomaticSystemFallback,
                onChanged: (value) => notifier.setTtsPreferences(
                  preferences.withAutomaticSystemFallback(value),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
