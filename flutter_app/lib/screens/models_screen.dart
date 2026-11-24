import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
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
    if (widget.initialLanguage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openLanguages(widget.initialLanguage);
      });
    }
  }

  void _openLanguages([String? initialLanguage]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsLanguagesScreen(initialLanguage: initialLanguage),
      ),
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Card(
              child: ListTile(
                key: const ValueKey('models-languages-row'),
                leading: const Icon(Icons.translate),
                title: Text(t.modelsLanguagesTitle),
                subtitle: Text(t.modelsSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: _openLanguages,
              ),
            ),
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
