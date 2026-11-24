import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/language_model_choices.dart';
import '../models/language_names.dart';
import '../models/tts_catalog.dart';
import '../models/tts_preferences.dart';
import '../services/conversion/embedded_conversion_contract.dart' show ManualTtsModelCatalog;
import '../services/conversion/model_install/model_install_models.dart';
import '../services/conversion/model_install/model_install_runner.dart';
import '../state/providers.dart';
import '../views/reader_narration_menu.dart'
    show installedNarrationModelIdsProvider;
import 'models_languages_screen.dart' show ModelsData, loadModelsData;

/// One language's voice, on its own page: Automatic first, then the SYSTEM voice, the PIPER
/// models of this device (quality and size as a subtitle; a tap downloads with progress in the
/// row) and the EDGE online voices (they need the online consent). Choosing a voice here is what
/// plays books in this language; Rust resolves Automatic at job start.
class ModelsLanguageScreen extends ConsumerStatefulWidget {
  const ModelsLanguageScreen({super.key, required this.language});

  /// Base language tag (`pt`, `en`).
  final String language;

  @override
  ConsumerState<ModelsLanguageScreen> createState() =>
      _ModelsLanguageScreenState();
}

class _ModelsLanguageScreenState extends ConsumerState<ModelsLanguageScreen> {
  late Future<ModelsData> _data = loadModelsData(ref);
  final Map<String, ModelInstallEvent?> _progress = {};
  final Map<String, ModelInstallCancellation> _cancellations = {};
  String? _error;

  String get _base => LanguageModelChoices.baseLanguage(widget.language);

  void _reload() {
    final next = loadModelsData(ref);
    setState(() {
      _data = next;
    });
  }

  static bool _isOnline(Map<String, dynamic> model) => model['engine'] == 'edge';

  static bool _serves(Map<String, dynamic> model, String base) {
    final tags = model['languages'];
    return tags is List &&
        tags.any((tag) => LanguageModelChoices.baseLanguage('$tag') == base);
  }

  static TtsSelection _selectionFor(Map<String, dynamic> model) => TtsSelection(
    engine: model['engine'] as String,
    modelId: model['id'] as String,
  );

  bool _chosen(LanguageModelChoices choices, Map<String, dynamic> model) {
    final choice = choices.choiceFor(_base);
    return choice != null &&
        choice.engine == model['engine'] &&
        choice.modelId == model['id'];
  }

  Future<void> _install(Map<String, dynamic> model) async {
    final id = model['id'] as String;
    if (_cancellations.containsKey(id)) return;
    final converter = ref.read(embeddedConverterProvider);
    final token = ModelInstallCancellation();
    setState(() {
      _error = null;
      _progress[id] = null;
      _cancellations[id] = token;
    });
    try {
      final root = await ref.read(ttsModelRootProvider.future);
      ModelInstallEvent? last;
      await for (final event in converter.installTtsModelWithProgress(
        modelId: id,
        root: root,
        cancellation: token,
      )) {
        last = event;
        if (mounted && !event.stage.terminal) {
          setState(() => _progress[id] = event);
        }
      }
      if (last?.stage == ModelInstallStage.completed) {
        // Tapping a voice to download it is choosing it for this language.
        ref.read(languageModelChoicesProvider.notifier).choose(_base, _selectionFor(model));
      } else if (last?.stage == ModelInstallStage.failed && mounted) {
        setState(() => _error = last?.failure?.message ?? id);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _cancellations.remove(id);
      _progress.remove(id);
      ref.invalidate(installedNarrationModelIdsProvider);
      if (mounted) _reload();
    }
  }

  /// A Piper Low voice is chosen with its catalog revision: the probe confirms the installed
  /// voice is ready, and only then is the choice stored (Rust accepts a Low voice no other way).
  Future<void> _chooseLow(TtsCatalog manual, Map<String, dynamic> model) async {
    final identity = manual.installedLowModels().where((m) => m.modelId == model['id']).firstOrNull;
    if (identity == null) return;
    try {
      final root = await ref.read(ttsModelRootProvider.future);
      final converter = ref.read(embeddedConverterProvider);
      if (converter is! ManualTtsModelCatalog) throw StateError('Manual probing is unavailable');
      final probe = await (converter as ManualTtsModelCatalog).probeTtsModel(
        modelId: identity.modelId!,
        root: root,
        language: _base,
      );
      final selection = TtsCatalog.decodeManual(probe).confirmedManualModel(identity);
      if (mounted) ref.read(languageModelChoicesProvider.notifier).choose(_base, selection);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.ttsManualModelUnavailable)),
      );
    }
  }

  void _choose(Map<String, dynamic> model) => ref
      .read(languageModelChoicesProvider.notifier)
      .choose(_base, _selectionFor(model));

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _radio(bool selected) => Icon(
    selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
    color: selected ? Theme.of(context).colorScheme.primary : null,
  );

  String? _details(AppLocalizations t, Map<String, dynamic> model) {
    final bytes = model['download_bytes'];
    final megabytes = bytes is num && bytes > 0 ? (bytes / 1000000).ceil() : null;
    return megabytes == null ? null : t.modelsSizeMb(megabytes);
  }

  Widget _modelTile({
    required Map<String, dynamic> model,
    required bool installed,
    required bool usable,
    required LanguageModelChoices choices,
    required AppLocalizations t,
  }) {
    final id = model['id'] as String;
    final installing = _cancellations.containsKey(id);
    final chosen = _chosen(choices, model);
    final theme = Theme.of(context);
    final details = _details(t, model);
    final subtitle = !usable
        ? t.modelsOnlineNeedsConsent
        : installed
        ? details
        : [t.modelsNotInstalled, ?details].join(' · ');
    return Column(
      children: [
        ListTile(
          key: ValueKey('model-$_base-$id'),
          enabled: usable,
          leading: _radio(chosen),
          title: Text(
            id,
            // Not installed is said by the subtitle and the download icon; the disabled color is 2.6:1.
            style: !installed && !installing
                ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: installing
              ? IconButton(
                  key: ValueKey('models-cancel-$id'),
                  icon: const Icon(Icons.close),
                  tooltip: MaterialLocalizations.of(context).cancelButtonLabel,
                  onPressed: () => _cancellations[id]?.cancel(),
                )
              : (!installed && usable ? const Icon(Icons.download_outlined) : null),
          onTap: !usable || installing
              ? null
              : installed
              ? () => _choose(model)
              : () => _install(model),
        ),
        if (installing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: LinearProgressIndicator(
              key: ValueKey('models-progress-$id'),
              value: _progress[id]?.fraction,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final choices = ref.watch(languageModelChoicesProvider);
    final allowOnline = ref.watch(settingsProvider).ttsPreferences.allowOnlineFallback;
    final systemVoices = ref.watch(systemVoiceLanguagesProvider).asData?.value ?? const <String>[];
    final choice = choices.choiceFor(_base);
    final showLow = ref.watch(showLowQualityModelsProvider);
    final manualCatalog = showLow ? ref.watch(manualLowCatalogProvider).asData?.value : null;
    // Installed Low voices that serve this language (they need the catalog revision to be chosen).
    final lowModels = manualCatalog == null
        ? const <Map<String, dynamic>>[]
        : [
            for (final identity in manualCatalog.installedLowModels())
              ...manualCatalog.models.where(
                (m) => m['id'] == identity.modelId && _serves(m, _base),
              ),
          ];
    return Scaffold(
      appBar: AppBar(title: Text(languageEndonym(_base))),
      body: ListView(
        children: [
          FutureBuilder<ModelsData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(t.modelsLoadFailed, textAlign: TextAlign.center),
                );
              }
              final data = snapshot.requireData;
              final models = data.models.where((m) => _serves(m, _base)).toList();
              final piper = models.where((m) => !_isOnline(m)).toList();
              final edge = models.where(_isOnline).toList();
              final speaksSystem = systemVoices.any(
                (tag) => LanguageModelChoices.baseLanguage(tag) == _base,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        _error!,
                        key: const ValueKey('models-error'),
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    ),
                  ListTile(
                    key: ValueKey('model-$_base-automatic'),
                    leading: _radio(choice == null),
                    title: Text(t.modelsAutomatic),
                    subtitle: Text(t.modelsAutomaticDesc),
                    onTap: () => ref.read(languageModelChoicesProvider.notifier).clear(_base),
                  ),
                  if (speaksSystem) ...[
                    _header(t.modelsSystemSection),
                    ListTile(
                      key: ValueKey('model-$_base-system'),
                      leading: _radio(choice?.engine == 'system'),
                      title: Text(t.modelsSystemVoice),
                      onTap: () => ref
                          .read(languageModelChoicesProvider.notifier)
                          .choose(_base, TtsSelection.system),
                    ),
                  ],
                  if (piper.isNotEmpty) ...[
                    _header(t.modelsPiperSection),
                    for (final model in piper)
                      _modelTile(
                        model: model,
                        installed: data.installed.contains(model['id']),
                        usable: true,
                                        choices: choices,
                        t: t,
                      ),
                  ],
                  if (lowModels.isNotEmpty) ...[
                    _header(t.modelsLowQualitySection),
                    for (final model in lowModels)
                      ListTile(
                        key: ValueKey('model-$_base-${model['id']}'),
                        leading: _radio(choice?.modelId == model['id'] && choice?.session != null),
                        title: Text('${model['id']}'),
                        subtitle: _details(t, model) == null ? null : Text(_details(t, model)!),
                        onTap: () => _chooseLow(manualCatalog!, model),
                      ),
                  ],
                  if (edge.isNotEmpty) ...[
                    _header(t.modelsEdgeSection),
                    for (final model in edge)
                      _modelTile(
                        model: model,
                        installed: data.installed.contains(model['id']),
                        usable: allowOnline,
                                        choices: choices,
                        t: t,
                      ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
