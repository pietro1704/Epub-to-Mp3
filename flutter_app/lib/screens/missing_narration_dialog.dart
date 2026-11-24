import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/language_names.dart';
import 'models_languages_screen.dart';
import 'models_screen.dart';

/// Tells the user no narration model is available for the book's language and
/// offers the Models screen at that language. It never downloads anything: the
/// install stays an explicit tap inside the Models screen.
Future<void> showMissingNarrationDialog(
  BuildContext context, {
  required String language,
}) async {
  final t = AppLocalizations.of(context)!;
  final open = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('missing-narration-dialog'),
      title: Text(t.modelsMissingTitle(languageEndonym(language))),
      content: Text(t.modelsMissingBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('missing-narration-open-models'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.modelsMissingAction),
        ),
      ],
    ),
  );
  if (open == true && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsScreen(initialLanguage: language),
      ),
    );
  }
}

/// A non-blocking notice, shown before the narration of a bilingual or multilingual book starts:
/// these languages have no installed voice and are read with the main voice. The action opens the
/// Models languages on the first of them; nothing is downloaded here.
void showMissingProfileModelsNotice(
  BuildContext context,
  List<String> languages,
) {
  if (languages.isEmpty) return;
  final t = AppLocalizations.of(context)!;
  final names = languages.map(languageEndonym).join(', ');
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      key: const ValueKey('missing-profile-models-notice'),
      duration: const Duration(seconds: 12),
      content: Text(t.bookLanguagesMissingModels(names)),
      action: SnackBarAction(
        label: t.modelsMissingAction,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                ModelsLanguagesScreen(initialLanguage: languages.first),
          ),
        ),
      ),
    ),
  );
}
