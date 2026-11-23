import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/language_names.dart';
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
