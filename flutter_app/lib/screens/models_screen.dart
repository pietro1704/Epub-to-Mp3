import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/language_model_choices.dart';
import '../models/language_names.dart';
import '../models/language_order.dart' show systemLocalesProvider;
import '../models/tts_preferences.dart';
import '../state/providers.dart';
import '../services/playback/global_voice_migration.dart';
import 'models_language_screen.dart';
import 'models_languages_screen.dart';
import 'settings_screen.dart'
    show InstalledNarrationModelsCard, VoiceSelectionSettings;

/// Narration settings: first the row that opens the languages (each language's model on its own
/// route: reachable without scrolling on a phone), then the default/reserve voice and the online
/// consent, and the installed models. Installing a
/// model is always an explicit tap on its row.
class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key, this.initialLanguage});

  /// Base language to open on (from the missing-model alert): the languages route opens with
  /// its section expanded.
  final String? initialLanguage;

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _migrateGlobalVoice());
    if (widget.initialLanguage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openLanguage(widget.initialLanguage!);
      });
    }
  }

  /// The old global primary voice becomes a per-language choice, once.
  Future<void> _migrateGlobalVoice() async {
    try {
      final data = await loadModelsData(ref);
      if (!mounted) return;
      await migrateGlobalVoiceToLanguageChoices(
        prefs: ref.read(sharedPrefsProvider),
        configured: ref.read(settingsProvider).configuredTtsPreferences,
        models: data.models,
        choiceFor: (language) => ref.read(languageModelChoicesProvider).choiceFor(language),
        choose: (language, selection) =>
            ref.read(languageModelChoicesProvider.notifier).choose(language, selection),
        savePreferences: (preferences) =>
            ref.read(settingsProvider.notifier).setTtsPreferences(preferences),
        deviceLanguages: [
          for (final l in ref.read(systemLocalesProvider)) l.languageCode.toLowerCase(),
        ],
        libraryLanguages: ref
            .read(bookLanguageCacheProvider)
            .knownPrimaryLanguages(
              corrected: (id) => ref.read(bookLanguageCorrectionsProvider).decision(id).bookLanguage,
            )
            .values
            .toList(),
      );
    } catch (_) {
      // The catalog is unavailable: the migration runs at a later visit.
    }
  }

  void _openLanguages([String? initialLanguage]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsLanguagesScreen(initialLanguage: initialLanguage),
      ),
    );
  }

  void _openLanguage(String language) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => ModelsLanguageScreen(language: language),
          ),
        )
        .then((_) {
          if (!mounted) return;
          final next = _loadRows();
          setState(() {
            _rows = next;
          });
        });
  }

  late Future<_LanguageRows> _rows = _loadRows();

  /// The languages worth a row here, each with the voice that plays it: the system's languages,
  /// the languages of the books in the library, and any language with a choice or an installed
  /// model. A row warns when a book of the library needs a language that has no voice.
  Future<_LanguageRows> _loadRows() async {
    final data = await loadModelsData(ref);
    final choices = ref.read(languageModelChoicesProvider);
    final corrections = ref.read(bookLanguageCorrectionsProvider);
    final books = ref
        .read(bookLanguageCacheProvider)
        .knownPrimaryLanguages(
          corrected: (id) => corrections.decision(id).bookLanguage,
        )
        .values
        .map(LanguageModelChoices.baseLanguage)
        .toSet();
    final systemVoices = (await ref.read(systemVoiceLanguagesProvider.future))
        .map(LanguageModelChoices.baseLanguage)
        .toSet();
    final catalogTags = data.languages.map((l) => l.tag).toSet();
    final installedByLanguage = <String, String>{};
    for (final model in data.models) {
      final id = model['id'];
      if (model['engine'] == 'edge' || !data.installed.contains(id)) continue;
      for (final tag in (model['languages'] as List? ?? const [])) {
        installedByLanguage.putIfAbsent(LanguageModelChoices.baseLanguage('$tag'), () => '$id');
      }
    }
    final wanted = <String>{
      ...ref.read(systemLocalesProvider).map((l) => l.languageCode.toLowerCase()),
      ...books,
      ...choices.byLanguage.keys,
      ...installedByLanguage.keys,
    }.where(catalogTags.contains).toList()
      ..sort((a, b) => languageEndonym(a).toLowerCase().compareTo(languageEndonym(b).toLowerCase()));
    return _LanguageRows([
      for (final base in wanted)
        _LanguageRow(
          base,
          choice: choices.choiceFor(base),
          installedModel: installedByLanguage[base],
          systemVoice: systemVoices.contains(base),
          needed: books.contains(base),
        ),
    ]);
  }

  Widget _languageTile(_LanguageRow row, LanguageModelChoices choices, AppLocalizations t) {
    final choice = choices.choiceFor(row.language);
    final voice = choice != null
        ? (choice.engine == 'system' ? t.modelsSystemVoice : choice.modelId ?? choice.displayName)
        : row.installedModel != null
        ? '${t.modelsAutomatic} · ${row.installedModel}'
        : row.systemVoice
        ? '${t.modelsAutomatic} · ${t.modelsSystemVoice}'
        : t.modelsAutomatic;
    final missing = choice == null && row.installedModel == null && !row.systemVoice && row.needed;
    return ListTile(
      key: ValueKey('models-language-${row.language}'),
      title: Text(languageEndonym(row.language)),
      subtitle: Text(missing ? t.modelsNeedsVoice : voice),
      leading: missing
          ? Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error)
          : null,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _openLanguage(row.language),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(t.modelsTitle)),
      // Default/reserve voice and the online consent live here, as on the
      // Apple Models screen (Settings keeps a single row). They stay available
      // even when the language catalog cannot be loaded.
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              t.modelsVoiceForEachLanguage,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          FutureBuilder<_LanguageRows>(
            future: _rows,
            builder: (context, snapshot) {
              final rows = snapshot.data?.rows ?? const <_LanguageRow>[];
              // The choices are watched so a row follows the language page at once.
              final choices = ref.watch(languageModelChoicesProvider);
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    for (final row in rows) _languageTile(row, choices, t),
                    ListTile(
                      key: const ValueKey('models-languages-row'),
                      leading: const Icon(Icons.translate),
                      title: Text(t.modelsAllLanguages),
                      subtitle: Text(t.modelsSubtitle),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openLanguages,
                    ),
                  ],
                ),
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: VoiceSelectionSettings(),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: InstalledNarrationModelsCard(),
          ),
        ],
      ),
    );
  }
}

class _LanguageRows {
  const _LanguageRows(this.rows);
  final List<_LanguageRow> rows;
}

class _LanguageRow {
  const _LanguageRow(
    this.language, {
    required this.choice,
    required this.installedModel,
    required this.systemVoice,
    required this.needed,
  });
  final String language;
  final TtsSelection? choice;
  final String? installedModel;
  final bool systemVoice;
  final bool needed;
}
