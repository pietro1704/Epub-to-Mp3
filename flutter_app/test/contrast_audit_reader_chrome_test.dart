// CONTRAST-AUDIT, area 6: the whole reader with its chrome (top bar, chapter header, tool buttons,
// indicator) and the panels it opens (search, table of contents, reading settings), in every
// reader theme, phone and tablet.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/design_system/app_theme.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/reading_preferences_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contrast_audit.dart';

EbookFulltext _book() => EbookFulltext.fromJson({
  'jobId': 'audit',
  'bookTitle': 'Sample Book',
  'bookAuthor': 'Author Name',
  'chapters': [
    for (var i = 0; i < 4; i++)
      {
        'index': i,
        'name': 'Chapter ${i + 1}',
        'text': List.generate(
          20,
          (n) =>
              'Sentence ${n + 1} of chapter ${i + 1}, with some text to read.',
        ).join(' '),
      },
  ],
});

Future<List<ContrastFinding>> _audit(
  WidgetTester tester,
  ReaderTheme theme,
  Size size,
  Brightness brightness, {
  required String panel,
}) async {
  SharedPreferences.setMockInitialValues({
    'readerLayout': 'paginated',
    'readerTheme': theme.rawValue,
  });
  final prefs = await SharedPreferences.getInstance();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    AuditHost(
      boundaryKey: key,
      child: ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: AppTheme.forBrightness(brightness),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: InstantReaderView(fulltext: _book())),
        ),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Finder panelFinder() => find.byType(BottomSheet).evaluate().isNotEmpty
      ? find.byType(BottomSheet)
      : find.byType(Dialog);
  final t = AppLocalizations.of(tester.element(find.byType(Scaffold).first))!;
  final more = find.byTooltip(
    MaterialLocalizations.of(tester.element(find.byType(Scaffold).first))
        .showMenuTooltip,
  );
  Finder? within;
  switch (panel) {
    case 'menu':
      await tester.tap(more.first);
      await settle();
      // Only the popup: the page under its corner is covered, not meant to be read.
      within = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString().startsWith('_PopupMenu'),
      );
    case 'contents':
      await tester.tap(more.first);
      await settle();
      await tester.tap(find.text(t.tableOfContents).first);
      await settle();
      within = panelFinder();
    case 'settings':
      // The tool beside More is the recent one; the others are in the menu.
      if (find.byIcon(Icons.text_format).evaluate().isNotEmpty) {
        await tester.tap(find.byIcon(Icons.text_format).first);
      } else {
        await tester.tap(more.first);
        await settle();
        await tester.tap(find.text(t.readerAppearance).first);
      }
      await settle();
      within = find.byType(ReadingPreferencesScreen);
  }
  // A scoped audit that finds nothing would pass vacuously.
  if (within != null) expect(within, findsWidgets);
  return auditContrast(tester, key, within: within);
}

void main() {
  const sizes = {
    'phone 400x800': Size(400, 800),
    'tablet 1280x800': Size(1280, 800),
  };
  for (final theme in ReaderTheme.values.where(
    (t) => t != ReaderTheme.auto && t != ReaderTheme.custom,
  )) {
    for (final size in sizes.entries) {
      for (final panel in ['reader', 'menu', 'contents', 'settings']) {
        for (final brightness in Brightness.values) {
          testWidgets(
            '${theme.name} ${size.key} $panel (${brightness.name} app): text and icons meet WCAG AA',
            (tester) async {
              final findings = await _audit(
                tester,
                theme,
                size.value,
                brightness,
                panel: panel,
              );
              final path = Platform.environment['CONTRAST_REPORT'];
              if (path != null) {
                File(path).writeAsStringSync(
                  '## reader ${theme.name} ${size.key} $panel (${brightness.name}): ${findings.length} violation(s)\n'
                  '${findings.map((f) => '- $f').join('\n')}\n\n',
                  mode: FileMode.append,
                );
              }
              expect(findings, isEmpty, reason: findings.join('\n'));
            },
          );
        }
      }
    }
  }
}
