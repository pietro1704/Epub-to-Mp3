import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/book_entity.dart';
import '../models/book_language_summary.dart';
import '../models/language_model_choices.dart';
import '../models/language_names.dart';
import '../models/language_order.dart';
import '../models/narration_plan.dart';
import '../services/conversion/embedded_conversion_contract.dart';
import '../state/providers.dart';
import 'library_screen.dart' show libraryStoreProvider;

/// The book's language sheet (Apple "book language sheet"): what was detected in the text
/// ("Português 90%, also written in Français, quotes in Latin"), a line when the file declares
/// another language than the text is written in, and the languages to choose from: the ones of
/// this book first, then the catalog in Models order. Returns the chosen tag, `''` for Automatic,
/// or null when dismissed. Rust decides what the text is; the sheet only shows it.
Future<String?> showBookLanguageSheet(
  BuildContext context,
  WidgetRef ref,
  BookEntity book,
) {
  final selected = ref.read(bookLanguageCorrectionsProvider).decision(book.id).bookLanguage;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _BookLanguageSheet(book: book, selected: selected, ref: ref),
  );
}

class _SheetData {
  const _SheetData({required this.summary, required this.declaredConflict, required this.catalog});
  final BookLanguageSummary summary;
  final String? declaredConflict;
  final List<String> catalog;
}

class _BookLanguageSheet extends StatefulWidget {
  const _BookLanguageSheet({required this.book, required this.selected, required this.ref});
  final BookEntity book;
  final String? selected;
  final WidgetRef ref;

  @override
  State<_BookLanguageSheet> createState() => _BookLanguageSheetState();
}

class _BookLanguageSheetState extends State<_BookLanguageSheet> {
  late final Future<_SheetData> _data = _load();

  Future<_SheetData> _load() async {
    final ref = widget.ref;
    final converter = ref.read(embeddedConverterProvider);
    final library = ref.read(libraryStoreProvider);
    final path = await library.ensureSupportedBookPath(widget.book);
    final analysis = await ref.read(bookLanguageCacheProvider).analysis(
      converter: converter,
      bookId: widget.book.id,
      path: path,
    );
    var summary = BookLanguageSummary.from(analysis);
    String? conflict;
    // The plan carries Rust's decision: the main language and whether the file contradicts it.
    if (converter is NarrationPlanCapable &&
        (converter as NarrationPlanCapable).supportsNarrationPlan) {
      try {
        final plan = await (converter as NarrationPlanCapable).bookNarrationPlan(
          NarrationPlanRequest(
            analysis: analysis,
            declared: analysis.declared,
            platform: _platform(),
          ),
        );
        conflict = plan.decision.declaredConflict;
        final language = plan.decision.language;
        if (language != null && language != summary.main) {
          summary = BookLanguageSummary(
            main: language,
            mainPercent: summary.mainPercent,
            alsoWritten: summary.alsoWritten,
            alsoQuoted: summary.alsoQuoted,
          );
        }
      } catch (error) {
        debugPrint('Narration plan unavailable for the language sheet: $error');
      }
    }
    var catalog = <String>[];
    try {
      final languages = await converter.ttsCatalogLanguages();
      final ordered = orderModelLanguages(languages, ref.read(systemLocalesProvider));
      catalog = [
        for (final group in [ordered.system, ordered.popular, ordered.others])
          for (final language in group) language.tag,
      ];
    } catch (_) {
      catalog = pickableLanguageTags;
    }
    return _SheetData(summary: summary, declaredConflict: conflict, catalog: catalog);
  }

  static String _platform() => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.macOS => 'Macos',
    TargetPlatform.iOS => 'Ios',
    _ => 'Linux',
  };

  String _names(List<String> tags) => tags.map(languageEndonym).join(', ');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: FutureBuilder<_SheetData>(
          future: _data,
          builder: (context, snapshot) {
            final data = snapshot.data;
            final loading = data == null && !snapshot.hasError;
            final detected = data == null
                ? const <String>[]
                : [
                    ?data.summary.main,
                    ...data.summary.alsoWritten,
                    ...data.summary.alsoQuoted,
                  ];
            final rest = data == null
                ? pickableLanguageTags
                : data.catalog.where((tag) => !detected.contains(tag)).toList();
            final current = widget.selected == null
                ? ''
                : LanguageModelChoices.baseLanguage(widget.selected!);
            Widget option(String tag, String label) => ListTile(
              key: ValueKey('book-language-$tag'),
              title: Text(label),
              trailing: LanguageModelChoices.baseLanguage(tag) == current && (tag.isNotEmpty || current.isEmpty)
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(context, tag),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(t.bookLanguageTitle, style: theme.textTheme.titleLarge),
                ),
                if (loading)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Row(
                      children: [
                        const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text(t.bookLanguageAnalyzing),
                      ],
                    ),
                  ),
                if (data != null && data.summary.main != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                    child: Text(
                      data.summary.mainPercent == null
                          ? t.bookLanguageSummaryMainOnly(languageEndonym(data.summary.main!))
                          : t.bookLanguageSummaryMain(
                              languageEndonym(data.summary.main!),
                              data.summary.mainPercent!,
                            ),
                      key: const ValueKey('book-language-summary'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                if (data != null && data.summary.alsoWritten.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 2),
                    child: Text(t.bookLanguageSummaryWritten(_names(data.summary.alsoWritten))),
                  ),
                if (data != null && data.summary.alsoQuoted.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 2),
                    child: Text(t.bookLanguageSummaryQuoted(_names(data.summary.alsoQuoted))),
                  ),
                if (data?.declaredConflict != null && data?.summary.main != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
                    child: Text(
                      t.bookLanguageConflict(
                        languageEndonym(LanguageModelChoices.baseLanguage(data!.declaredConflict!)),
                        languageEndonym(data.summary.main!),
                      ),
                      key: const ValueKey('book-language-conflict'),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      option('', t.bookLanguageAutomatic),
                      if (detected.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                          child: Text(
                            t.bookLanguageDetectedSection,
                            style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                          ),
                        ),
                        for (final tag in detected) option(tag, languageChoiceLabel(tag)),
                        const Divider(),
                      ],
                      for (final tag in rest) option(tag, languageChoiceLabel(tag)),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
