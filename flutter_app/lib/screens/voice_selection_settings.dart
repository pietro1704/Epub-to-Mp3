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
    final primaryKey = jsonEncode(preferences.primary.toJson());
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
    String selectionLabel(TtsSelection selection) =>
        ttsSelectionLabel(t, selection);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Audio Engine ──
        _SectionHeader(t.audioEngineSection),
        Card(
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey('primary-$_primaryFieldRevision-$primaryKey'),
                initialValue: primaryKey,
                decoration: InputDecoration(labelText: t.ttsPrimaryNarration),
                items: primaryOptions.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        enabled:
                            !entry.value.manualModel ||
                            (showLow && entry.key != primaryKey),
                        child: Text(selectionLabel(entry.value)),
                      ),
                    )
                    .toList(),
                onChanged: (key) async {
                  final selected = primaryOptions[key];
                  if (selected == null) return;
                  if (selected.manualModel) {
                    if (manualCatalog != null &&
                        ref.read(showLowQualityModelsProvider) &&
                        key != primaryKey) {
                      await _selectManualPrimary(
                        selected.session!,
                        manualCatalog,
                        recommended,
                      );
                    } else {
                      setState(() => _primaryFieldRevision++);
                    }
                    return;
                  }
                  _primaryRequest++;
                  await notifier.setTtsPreferences(
                    preferences.withPrimary(selected),
                  );
                },
              ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey(
                  'secondary-${jsonEncode(preferences.primary.toJson())}-${jsonEncode(preferences.secondary?.toJson())}',
                ),
                initialValue: preferences.secondary == null
                    ? 'none'
                    : jsonEncode(preferences.secondary!.toJson()),
                decoration: InputDecoration(labelText: t.ttsSecondaryNarration),
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
                value: preferences.allowOnlineFallback,
                onChanged: (value) {
                  final prefs = preferences;
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
