part of 'settings_screen.dart';

class VoiceSelectionSettings extends ConsumerWidget {
  const VoiceSelectionSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final preferences = settings.ttsPreferences;
    final catalogSelections = ref.watch(_ttsCatalogSelections).asData?.value ?? const <TtsSelection>[];
    Map<String, TtsSelection> uniqueOptions(Iterable<TtsSelection> candidates) {
      final result = <String, TtsSelection>{};
      for (final selection in candidates) {
        if (!result.values.any((existing) => existing.representsSameRequest(selection))) {
          result[jsonEncode(selection.toJson())] = selection;
        }
      }
      return result;
    }
    final primaryOptions = uniqueOptions([preferences.primary, ...catalogSelections,
      TtsSelection.faber, TtsSelection.edge, TtsSelection.system]);
    final secondaryOptions = uniqueOptions([?preferences.secondary, ...catalogSelections,
      TtsSelection.faber, TtsSelection.edge, TtsSelection.system].where((selection) => !selection.representsSameRequest(preferences.primary)));
    String selectionLabel(TtsSelection selection) {
      if (selection.representsSameRequest(TtsSelection.faber)) {
        return t.ttsFaberOffline;
      }
      if (selection.representsSameRequest(TtsSelection.edge)) {
        return t.ttsEdgeOnline;
      }
      if (selection.engine == 'system') return t.ttsSystemOffline;
      return selection.displayName;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Audio Engine ──
        _SectionHeader(t.audioEngineSection),
        Card(
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'primary-${jsonEncode(preferences.primary.toJson())}',
                ),
                initialValue: jsonEncode(preferences.primary.toJson()),
                decoration: InputDecoration(labelText: t.ttsPrimaryNarration),
                items: primaryOptions.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(selectionLabel(entry.value)),
                      ),
                    )
                    .toList(),
                onChanged: (key) {
                  final selected = primaryOptions[key];
                  if (selected == null) return;
                  notifier.setTtsPreferences(preferences.withPrimary(selected));
                },
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'secondary-${jsonEncode(preferences.primary.toJson())}-${jsonEncode(preferences.secondary?.toJson())}',
                ),
                initialValue: preferences.secondary == null
                    ? 'none'
                    : jsonEncode(preferences.secondary!.toJson()),
                decoration: InputDecoration(
                  labelText: t.ttsSecondaryNarration,
                ),
                items: [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text(t.ttsNoSecondary),
                  ),
                  ...secondaryOptions.entries.map(
                    (entry) => DropdownMenuItem(
                      value: entry.key,
                      enabled:
                          entry.value.engine != 'edge' ||
                          preferences.allowOnlineFallback,
                      child: Text(selectionLabel(entry.value)),
                    ),
                  ),
                ],
                onChanged: (key) {
                  notifier.setTtsPreferences(
                    TtsPreferences(
                      primary: preferences.primary,
                      secondary: secondaryOptions[key],
                      allowOnlineFallback: preferences.allowOnlineFallback,
                      policyVersion: 2,
                    ),
                  );
                },
              ),
              SwitchListTile(
                title: Text(t.ttsAllowOnlineSecondary),
                subtitle: Text(t.ttsOnlineSecondaryDescription),
                value: settings.ttsPreferences.allowOnlineFallback,
                onChanged: (value) {
                  final prefs = settings.ttsPreferences;
                  notifier.setTtsPreferences(
                    TtsPreferences(
                      primary: prefs.primary,
                      secondary: !value && prefs.secondary?.engine == 'edge'
                          ? null
                          : prefs.secondary,
                      allowOnlineFallback: value,
                      policyVersion: prefs.policyVersion,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        TextButton(
          key: const ValueKey('tts-use-recommended-defaults'),
          onPressed: () => notifier.setTtsPreferences(
            const TtsPreferences.appDefaults(),
          ),
          child: Text(t.ttsUseRecommendedDefaults),
        ),
      ],
    );
  }
}
