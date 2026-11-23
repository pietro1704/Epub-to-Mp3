import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/language_model_choices.dart';
import '../models/language_names.dart';
import '../models/language_model_resolution.dart';
import '../models/tts_catalog.dart';
import '../models/tts_preferences.dart';
import '../services/conversion/model_install/model_install_models.dart';
import '../services/conversion/model_install/model_install_runner.dart';
import '../state/providers.dart';

/// Narration models grouped by book language. The user picks, per language,
/// which model plays books in it (or Automatic); Rust resolves the rest at job
/// start. Installing a model is always an explicit tap on its row.
class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsData {
  const _ModelsData(this.languages, this.models, this.installed);
  final List<TtsCatalogLanguage> languages;
  final List<Map<String, dynamic>> models;
  final Set<String> installed;
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  late Future<_ModelsData> _data = _load();
  final Map<String, ModelInstallEvent?> _progress = {};
  final Map<String, ModelInstallCancellation> _cancellations = {};
  String? _error;

  Future<_ModelsData> _load() async {
    final converter = ref.read(embeddedConverterProvider);
    final languages = await converter.ttsCatalogLanguages();
    final models = TtsCatalog.decode(await converter.ttsModels()).models;
    final root = await ref.read(ttsModelRootProvider.future);
    final installed = <String>{};
    for (final model in models) {
      final id = model['id'];
      if (id is! String || id.isEmpty) continue;
      // Online voices have nothing to install: always usable once consented.
      if (model['engine'] == 'edge' ||
          await converter.ttsModelMetadata(modelId: id, root: root) != null) {
        installed.add(id);
      }
    }
    return _ModelsData(languages, models, installed);
  }

  void _reload() {
    final next = _load();
    setState(() {
      _data = next;
    });
  }

  static bool _isOnline(Map<String, dynamic> model) => model['engine'] == 'edge';

  static bool _servesLanguage(Map<String, dynamic> model, String base) {
    final tags = model['languages'];
    return tags is List &&
        tags.any((tag) => LanguageModelChoices.baseLanguage('$tag') == base);
  }

  static TtsSelection _selectionFor(Map<String, dynamic> model) =>
      TtsSelection(engine: model['engine'] as String, modelId: model['id'] as String);

  bool _isChosen(LanguageModelChoices choices, String language, Map<String, dynamic> model) {
    final choice = choices.choiceFor(language);
    return choice != null &&
        choice.engine == model['engine'] &&
        choice.modelId == model['id'];
  }

  Future<void> _install(String language, Map<String, dynamic> model) async {
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
        if (mounted && !event.stage.terminal) setState(() => _progress[id] = event);
      }
      if (last?.stage == ModelInstallStage.completed) {
        ref
            .read(languageModelChoicesProvider.notifier)
            .choose(language, _selectionFor(model));
      } else if (last?.stage == ModelInstallStage.failed && mounted) {
        setState(() => _error = last?.failure?.message ?? id);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      _cancellations.remove(id);
      _progress.remove(id);
      if (mounted) _reload();
    }
  }

  void _choose(String language, Map<String, dynamic> model) => ref
      .read(languageModelChoicesProvider.notifier)
      .choose(language, _selectionFor(model));

  Widget _modelTile({
    required String language,
    required Map<String, dynamic> model,
    required bool installed,
    required bool usable,
    required LanguageModelChoices choices,
    required AppLocalizations t,
  }) {
    final id = model['id'] as String;
    final installing = _cancellations.containsKey(id);
    final chosen = _isChosen(choices, language, model);
    final dim = !installed && !installing;
    final theme = Theme.of(context);
    return Column(
      children: [
        ListTile(
          key: ValueKey('model-$language-$id'),
          enabled: usable,
          leading: Icon(
            chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: chosen ? theme.colorScheme.primary : null,
          ),
          title: Text(
            id,
            style: dim ? TextStyle(color: theme.disabledColor) : null,
          ),
          subtitle: !usable
              ? Text(t.modelsOnlineNeedsConsent)
              : installed
              ? null
              : Text(t.modelsNotInstalled),
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
              ? () => _choose(language, model)
              : () => _install(language, model),
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

  Widget _languageSection(
    TtsCatalogLanguage language,
    _ModelsData data,
    LanguageModelChoices choices,
    bool allowOnline,
    AppLocalizations t,
  ) {
    final base = language.tag;
    final models = data.models.where((m) => _servesLanguage(m, base)).toList();
    final local = models.where((m) => !_isOnline(m)).toList();
    final online = models.where(_isOnline).toList();
    final choice = choices.choiceFor(base);
    final header = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.primary,
    );
    return ExpansionTile(
      key: ValueKey('language-$base'),
      title: Text(languageEndonym(base)),
      subtitle: Text(
        '${choice == null ? t.modelsAutomatic : choice.modelId ?? choice.displayName}'
        ' · ${t.modelsRowSubtitle(language.modelCount)}',
      ),
      children: [
        ListTile(
          key: ValueKey('model-$base-automatic'),
          leading: Icon(
            choice == null ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: choice == null ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(t.modelsAutomatic),
          subtitle: Text(t.modelsAutomaticDesc),
          onTap: () => ref.read(languageModelChoicesProvider.notifier).clear(base),
        ),
        if (local.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(alignment: Alignment.centerLeft, child: Text(t.modelsLocalSection, style: header)),
          ),
        for (final model in local)
          _modelTile(
            language: base,
            model: model,
            installed: data.installed.contains(model['id']),
            usable: true,
            choices: choices,
            t: t,
          ),
        if (online.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(alignment: Alignment.centerLeft, child: Text(t.modelsOnlineSection, style: header)),
          ),
        for (final model in online)
          _modelTile(
            language: base,
            model: model,
            installed: data.installed.contains(model['id']),
            usable: allowOnline,
            choices: choices,
            t: t,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final choices = ref.watch(languageModelChoicesProvider);
    final allowOnline = ref.watch(settingsProvider).ttsPreferences.allowOnlineFallback;
    return Scaffold(
      appBar: AppBar(title: Text(t.modelsTitle)),
      body: FutureBuilder<_ModelsData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t.modelsLoadFailed, textAlign: TextAlign.center),
              ),
            );
          }
          final data = snapshot.requireData;
          if (data.languages.isEmpty) {
            return Center(child: Text(t.modelsEmpty));
          }
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(t.modelsSubtitle, style: Theme.of(context).textTheme.bodyMedium),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    _error!,
                    key: const ValueKey('models-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              for (final language in data.languages)
                _languageSection(language, data, choices, allowOnline, t),
            ],
          );
        },
      ),
    );
  }
}
