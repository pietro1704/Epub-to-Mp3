// CONTRAST-AUDIT, area 4: the Models languages route (open on a language with model rows), the
// missing-model dialog, the missing-language-models snackbar and a library with a book.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/design_system/app_theme.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/screens/missing_narration_dialog.dart';
import 'package:flutter_app/screens/models_languages_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contrast_audit.dart';

Map<String, Object?> _entry(String provider, String id, List<String> tags) => {
  'identity': {
    'provider': provider,
    'runtime': provider,
    'model_id': id,
    'model_revision': 'r1',
  },
  'compatibility': {
    'runtime_available': true,
    'platforms': ['Linux'],
  },
  'distribution': {'installable': true, 'download_bytes': 1000},
  'language_evidence': {'routing_tags': tags},
};

class _Converter extends UnavailableEmbeddedConverter {
  @override
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages() async => const [
    TtsCatalogLanguage(tag: 'en', modelCount: 1, popularityRank: 1),
    TtsCatalogLanguage(tag: 'pt', modelCount: 3, popularityRank: 3),
    TtsCatalogLanguage(tag: 'is', modelCount: 1),
  ];

  @override
  Future<String> ttsModels() async => jsonEncode({
    'schema_version': 3,
    'providers': [
      {
        'provider': 'piper',
        'runtime': 'piper',
        'targets': ['linux'],
        'capabilities': {},
      },
      {
        'provider': 'edge',
        'runtime': 'edge',
        'targets': ['linux'],
        'capabilities': {},
      },
    ],
    'entries': [
      _entry('piper', 'pt_BR-faber-medium', ['pt-BR']),
      _entry('piper', 'pt_PT-tugao-medium', ['pt-PT']),
      _entry('piper', 'en_US-lessac-medium', ['en-US']),
      _entry('edge', 'edge-pt', ['pt-BR']),
    ],
  });

  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => modelId == 'pt_BR-faber-medium' ? '{}' : null;
}

Future<List<ContrastFinding>> _audit(
  WidgetTester tester,
  Brightness brightness,
  bool highContrast,
  Widget screen, {
  Map<String, Object> prefsData = const {},
  Future<void> Function(WidgetTester tester)? afterPump,
  Finder? within,
}) async {
  SharedPreferences.setMockInitialValues(prefsData);
  final prefs = await SharedPreferences.getInstance();
  final key = GlobalKey();
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AuditHost(
      boundaryKey: key,
      child: ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          embeddedConverterProvider.overrideWithValue(_Converter()),
          ttsModelRootProvider.overrideWith((_) => '/fixture-models'),
        ],
        child: MaterialApp(
          theme: AppTheme.forBrightness(brightness, highContrast: highContrast),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: screen,
        ),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  if (afterPump != null) {
    await afterPump(tester);
  }
  return auditContrast(tester, key, within: within);
}

Widget _opener(void Function(BuildContext) open) => Scaffold(
  body: Builder(
    builder: (context) => Center(
      child: TextButton(
        onPressed: () => open(context),
        child: const Text('open'),
      ),
    ),
  ),
);

Future<void> _tapOpen(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  final book = BookEntity(
    id: 'b1',
    title: 'A Book With A Title',
    author: 'An Author',
    filePath: '/tmp/b1.epub',
    displayFilename: 'b1.epub',
    addedAt: DateTime(2025, 1, 1),
  );
  final cases =
      <
        String,
        (
          Widget,
          Map<String, Object>,
          Future<void> Function(WidgetTester)?,
          Finder?,
        )
      >{
        'Languages route (open on Portuguese)': (
          const ModelsLanguagesScreen(initialLanguage: 'pt'),
          {},
          null,
          null,
        ),
        'Missing-model dialog': (
          _opener(
            (context) => showMissingNarrationDialog(context, language: 'pt'),
          ),
          {},
          _tapOpen,
          find.byType(AlertDialog),
        ),
        'Missing-language-models snackbar': (
          _opener(
            (context) =>
                showMissingProfileModelsNotice(context, const ['en', 'is']),
          ),
          {},
          _tapOpen,
          find.byType(SnackBar),
        ),
        'Library with a book': (
          const LibraryScreen(),
          {'library.books.v1': '[${book.encode()}]'},
          null,
          null,
        ),
      };
  for (final entry in cases.entries) {
    for (final brightness in Brightness.values) {
      for (final highContrast in [false, true]) {
        final mode =
            '${brightness.name}${highContrast ? ' + Increase Contrast' : ''}';
        testWidgets(
          '${entry.key}: every text and icon meets WCAG AA in $mode',
          (tester) async {
            final (screen, prefs, after, within) = entry.value;
            final findings = await _audit(
              tester,
              brightness,
              highContrast,
              screen,
              prefsData: prefs,
              afterPump: after,
              within: within,
            );
            expect(findings, isEmpty, reason: findings.join('\n'));
          },
        );
      }
    }
  }
}
