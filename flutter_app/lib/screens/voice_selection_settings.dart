part of 'settings_screen.dart';

class VoiceSelectionSettings extends ConsumerStatefulWidget {
  const VoiceSelectionSettings({super.key});

  @override
  ConsumerState<VoiceSelectionSettings> createState() =>
      _VoiceSelectionSettingsState();
}

class _VoiceSelectionSettingsState
    extends ConsumerState<VoiceSelectionSettings> {
  int _primaryRequest = 0;
  int _primaryFieldRevision = 0;

  bool _isCurrentManualRequest(int request) =>
      mounted &&
      request == _primaryRequest &&
      ref.read(showLowQualityModelsProvider);

  Future<void> _selectManualPrimary(
    TtsSessionSelection identity,
    TtsCatalog catalog,
    TtsPreferences recommended,
  ) async {
    final request = ++_primaryRequest;
    // Restore the committed value while the selected voice is being verified.
    setState(() => _primaryFieldRevision++);
    try {
      final root = await ref.read(ttsModelRootProvider.future);
      if (!_isCurrentManualRequest(request)) return;
      final converter = ref.read(embeddedConverterProvider);
      if (converter is! ManualTtsModelCatalog) {
        throw StateError('Manual TTS model probing is unavailable');
      }
      final probeJson = await (converter as ManualTtsModelCatalog)
          .probeTtsModel(
            modelId: identity.modelId!,
            root: root,
            language: catalog.manualModelLanguage(identity),
          );
      if (!_isCurrentManualRequest(request)) return;
      final selection = TtsCatalog.decodeManual(probeJson)
          .confirmedManualModel(identity);
      final preferences =
          ref.read(settingsProvider).configuredTtsPreferences ?? recommended;
      await ref
          .read(settingsProvider.notifier)
          .setTtsPreferences(preferences.withPrimary(selection));
    } catch (_) {
      if (!mounted || !_isCurrentManualRequest(request)) return;
      final t = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.ttsManualModelUnavailable)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final catalog = ref.watch(ttsCatalogProvider).asData?.value;
    final recommended =
        catalog?.recommendedPreferences ?? const TtsPreferences.appDefaults();
    final preferences = settings.configuredTtsPreferences ?? recommended;
    final catalogSelections = catalog?.selections() ?? const <TtsSelection>[];
    final showLow = ref.watch(showLowQualityModelsProvider);
    ref.listen(showLowQualityModelsProvider, (_, enabled) {
      if (!enabled) _primaryRequest++;
    });
    final manualCatalog = showLow
        ? ref.watch(manualLowCatalogProvider).asData?.value
        : null;
    final installedLowModels = manualCatalog?.installedLowModels() ?? const [];
    Map<String, TtsSelection> uniqueOptions(Iterable<TtsSelection> candidates) {
      final result = <String, TtsSelection>{};
      for (final selection in candidates) {
        if (!result.values.any(
          (existing) => existing.representsSameRequest(selection),
        )) {
          result[jsonEncode(selection.toJson())] = selection;
        }
      }
      return result;
    }

    final primaryOptions = uniqueOptions([
      preferences.primary,
      ...catalogSelections,
      for (final identity in installedLowModels)
        TtsSelection(
          engine: identity.provider,
          modelId: identity.modelId,
          session: identity,
          manualModel: true,
        ),
      TtsSelection.faber,
      recommended.primary,
      TtsSelection.edge,
      TtsSelection.system,
    ]);
    final secondaryOptions = uniqueOptions(
      [
        ?preferences.secondary,
        ...catalogSelections,
        TtsSelection.faber,
        TtsSelection.edge,
        TtsSelection.system,
      ].where(
        (selection) => !selection.representsSameRequest(preferences.primary),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Audio Engine ──
        _SectionHeader(t.audioEngineSection),
        Card(
          child: Column(
            children: [
              NarrationChoiceRow(
                key: const ValueKey('narration-primary-row'),
                label: t.ttsPrimaryNarration,
                selection: preferences.primary,
                onTap: () async {
                  final pick = await showNarrationPicker(
                    context,
                    title: t.ttsPrimaryNarration,
                    options: primaryOptions.values.toList(),
                    current: preferences.primary,
                    // Edge is online speech: as the primary voice it needs the
                    // same consent as the online fallback, so it is not offered
                    // until the user allows it (a saved Edge primary stays).
                    enabled: (selection) =>
                        (!selection.manualModel ||
                            (showLow &&
                                !selection.representsSameRequest(
                                  preferences.primary,
                                ))) &&
                        (selection.engine != 'edge' ||
                            preferences.allowOnlineFallback ||
                            selection.representsSameRequest(
                              preferences.primary,
                            )),
                  );
                  final selected = pick?.selection;
                  if (selected == null || !mounted) return;
                  if (selected.representsSameRequest(preferences.primary) &&
                      !selected.manualModel) {
                    return;
                  }
                  if (selected.manualModel) {
                    if (manualCatalog != null &&
                        ref.read(showLowQualityModelsProvider)) {
                      await _selectManualPrimary(
                        selected.session!,
                        manualCatalog,
                        recommended,
                      );
                    }
                    return;
                  }
                  _primaryRequest++;
                  await notifier.setTtsPreferences(
                    preferences.withPrimary(selected),
                  );
                },
              ),
              NarrationChoiceRow(
                key: const ValueKey('narration-secondary-row'),
                label: t.ttsSecondaryNarration,
                selection: preferences.secondary,
                onTap: () async {
                  final pick = await showNarrationPicker(
                    context,
                    title: t.ttsSecondaryNarration,
                    options: secondaryOptions.values.toList(),
                    current: preferences.secondary,
                    allowNone: true,
                    enabled: (selection) =>
                        selection.engine != 'edge' ||
                        preferences.allowOnlineFallback,
                  );
                  if (pick == null || !mounted) return;
                  await notifier.setTtsPreferences(
                    TtsPreferences(
                      primary: preferences.primary,
                      secondary: pick.selection,
                      allowOnlineFallback: preferences.allowOnlineFallback,
                      // Keep an explicit "no automatic system voice" policy.
                      policyVersion: preferences.policyVersion == 3 ? 3 : 2,
                      footnoteNarration: preferences.footnoteNarration,
                    ),
                  );
                },
              ),
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
        TextButton(
          key: const ValueKey('tts-use-recommended-defaults'),
          onPressed: () {
            _primaryRequest++;
            notifier.setTtsPreferences(recommended);
          },
          child: Text(t.ttsUseRecommendedDefaults),
        ),
      ],
    );
  }
}
