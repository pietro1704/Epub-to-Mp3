import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/language_model_choices.dart';
import '../models/language_names.dart';
import '../models/language_model_resolution.dart';
import '../models/language_order.dart';
import '../models/tts_catalog.dart';
import '../state/providers.dart';
import 'models_language_screen.dart';

/// Every language of the catalog, on its own route: the system's languages first,
/// then the most popular, then the rest alphabetically. The user picks, per language,
/// which model plays books in it (or Automatic); Rust resolves the rest at job
/// start. Installing a model is always an explicit tap on its row.
class ModelsData {
  const ModelsData(this.languages, this.models, this.installed);
  final List<TtsCatalogLanguage> languages;
  final List<Map<String, dynamic>> models;
  final Set<String> installed;
}

/// The catalog languages, the catalog models and which of them are installed (online voices
/// count as installed: nothing to download).
Future<ModelsData> loadModelsData(WidgetRef ref) async {
  final converter = ref.read(embeddedConverterProvider);
  final languages = await converter.ttsCatalogLanguages();
  final models = TtsCatalog.decode(await converter.ttsModels()).models;
  final root = await ref.read(ttsModelRootProvider.future);
  final installed = <String>{};
  for (final model in models) {
    final id = model['id'];
    if (id is! String || id.isEmpty) continue;
    if (model['engine'] == 'edge' ||
        await converter.ttsModelMetadata(modelId: id, root: root) != null) {
      installed.add(id);
    }
  }
  return ModelsData(languages, models, installed);
}

class ModelsLanguagesScreen extends ConsumerStatefulWidget {
  const ModelsLanguagesScreen({super.key, this.initialLanguage});

  /// Base language whose page opens at once (from the missing-model alert).
  final String? initialLanguage;

  @override
  ConsumerState<ModelsLanguagesScreen> createState() =>
      _ModelsLanguagesScreenState();
}

class _ModelsLanguagesScreenState extends ConsumerState<ModelsLanguagesScreen> {
  late final Future<ModelsData> _data = loadModelsData(ref);

  @override
  void initState() {
    super.initState();
    final language = widget.initialLanguage;
    if (language != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(language);
      });
    }
  }

  void _open(String language) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsLanguageScreen(language: language),
      ),
    );
  }

  Widget _row(
    TtsCatalogLanguage language,
    LanguageModelChoices choices,
    AppLocalizations t,
  ) {
    final base = language.tag;
    final choice = choices.choiceFor(base);
    return ListTile(
      key: ValueKey('language-$base'),
      title: Text(languageEndonym(base)),
      subtitle: Text(
        '${choice == null ? t.modelsAutomatic : choice.modelId ?? choice.displayName}'
        ' · ${t.modelsRowSubtitle(language.modelCount)}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(base),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final choices = ref.watch(languageModelChoicesProvider);
    final locales = ref.watch(systemLocalesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(t.modelsAllLanguages)),
      body: ListView(
        children: [
          FutureBuilder<ModelsData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done &&
                  !snapshot.hasData) {
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
              if (data.languages.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(child: Text(t.modelsEmpty)),
                );
              }
              final ordered = orderModelLanguages(data.languages, locales);
              Widget header(String text, Key key) => Padding(
                key: key,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  text,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      t.modelsSubtitle,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  for (final group in [
                    (
                      const ValueKey('models-group-system'),
                      t.modelsSystemLanguages,
                      ordered.system,
                    ),
                    (
                      const ValueKey('models-group-popular'),
                      t.modelsPopularLanguages,
                      ordered.popular,
                    ),
                    (
                      const ValueKey('models-group-others'),
                      t.modelsOtherLanguages,
                      ordered.others,
                    ),
                  ])
                    if (group.$3.isNotEmpty) ...[
                      header(group.$2, group.$1),
                      for (final language in group.$3) _row(language, choices, t),
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
