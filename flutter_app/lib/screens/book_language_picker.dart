import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/language_names.dart';

/// Asks which language a book or passage is in (Apple `BookLanguagePicker`).
///
/// Returns the chosen tag, `''` for "Automatic detection" (only when
/// [allowsAutomatic]), or null when the user cancels. [inconclusive] shows the
/// help for an undetectable language instead of the correction help.
Future<String?> showBookLanguagePicker(
  BuildContext context, {
  required bool allowsAutomatic,
  String? selected,
  bool inconclusive = false,
}) {
  final t = AppLocalizations.of(context)!;
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.bookLanguageTitle),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                inconclusive ? t.bookLanguageInconclusive : t.bookLanguageHelp,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (allowsAutomatic)
                    _option(
                      context,
                      '',
                      t.bookLanguageAutomatic,
                      (selected ?? '') == '',
                    ),
                  for (final tag in pickableLanguageTags)
                    _option(context, tag, languageChoiceLabel(tag), selected == tag),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    ),
  );
}

Widget _option(BuildContext context, String tag, String label, bool current) {
  return ListTile(
    title: Text(label),
    trailing: current ? const Icon(Icons.check) : null,
    selected: current,
    onTap: () => Navigator.pop(context, tag),
  );
}
