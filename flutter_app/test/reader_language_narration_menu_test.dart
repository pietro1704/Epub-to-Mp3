import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/tts_catalog.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/models_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_narration_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _entry(String provider, String id, List<String> tags) => {
  'identity': {'provider': provider, 'runtime': provider, 'model_id': id, 'model_revision': 'r1'},
  'compatibility': {'runtime_available': true, 'platforms': ['Linux', 'Android', 'Windows']},
  'distribution': {'installable': true, 'download_bytes': 1000},
  'language_evidence': {'routing_tags': tags},
};

TtsCatalog _catalog() => TtsCatalog.decode(jsonEncode({
  'schema_version': 3,
  'providers': [
    {'provider': 'piper', 'runtime': 'piper', 'targets': ['linux', 'android', 'windows'], 'capabilities': {}},
    {'provider': 'edge', 'runtime': 'edge', 'targets': ['linux', 'android', 'windows'], 'capabilities': {}},
  ],
  'entries': [
    _entry('piper', 'pt_BR-faber-medium', ['pt-BR']),
    _entry('piper', 'en_US-ljspeech-medium', ['en-US']),
    _entry('piper', 'en_GB-cori-medium', ['en-GB']),
    _entry('edge', 'edge-en', ['en-US']),
  ],
}));

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required String? language,
  Set<String> installed = const {'pt_BR-faber-medium', 'en_US-ljspeech-medium'},
  List<String> systemVoices = const [],
  TtsPreferences? saved,
  List<TtsSelection>? changes,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (saved != null) await AppSettings(prefs).setTtsPreferences(saved);
  final catalog = _catalog();
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      ttsCatalogProvider.overrideWith((ref) async => catalog),
      installedNarrationModelIdsProvider.overrideWith((ref) async => installed),
      systemVoiceLanguagesProvider.overrideWith((ref) async => systemVoices),
      readerBookLanguageProvider('book-1').overrideWith((ref) async => language),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(
            actions: [
              ReaderNarrationMenu(
                bookId: 'book-1',
                onChanged: (selection, _) async => changes?.add(selection),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return container;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reader-overflow-menu')));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<String> _labels(WidgetTester tester) => [
  for (final item in tester.widgetList<CheckedPopupMenuItem<Object>>(find.byType(CheckedPopupMenuItem<Object>)))
    (item.child! as Text).data!,
];

void main() {
  testWidgets('an English book lists only English models that are installed', (tester) async {
    await _pump(tester, language: 'en');
    await _open(tester);
    final labels = _labels(tester);
    expect(labels.any((l) => l.contains('ljspeech')), isTrue);
    expect(labels.any((l) => l.contains('Faber')), isFalse, reason: 'Portuguese model');
    expect(labels.any((l) => l.contains('cori')), isFalse, reason: 'not installed');
    expect(labels, contains('Piper · Book language'), reason: 'the active voice stays listed');
    expect(find.byKey(const ValueKey('reader-menu-open-models')), findsNothing);
  });

  testWidgets('the system voice is listed only when the platform speaks the language', (tester) async {
    await _pump(tester, language: 'en', systemVoices: const ['pt-br']);
    await _open(tester);
    expect(_labels(tester).any((l) => l.startsWith('System voice')), isFalse);
  });

  testWidgets('the system voice is listed when a voice exists for the language', (tester) async {
    await _pump(tester, language: 'en', systemVoices: const ['en-us']);
    await _open(tester);
    expect(_labels(tester).any((l) => l.startsWith('System voice')), isTrue);
  });

  testWidgets('online speech needs the consent', (tester) async {
    await _pump(tester, language: 'en');
    await _open(tester);
    expect(_labels(tester).any((l) => l.startsWith('Edge')), isFalse);
  });

  testWidgets('online speech is listed once consented', (tester) async {
    await _pump(
      tester,
      language: 'en',
      saved: const TtsPreferences(primary: TtsSelection.automaticPiper, allowOnlineFallback: true, policyVersion: 2),
    );
    await _open(tester);
    expect(_labels(tester).any((l) => l.startsWith('Edge')), isTrue);
  });

  testWidgets('choosing keeps the language choice in step with the switch', (tester) async {
    final changes = <TtsSelection>[];
    final container = await _pump(tester, language: 'en', changes: changes);
    await _open(tester);
    await tester.tap(find.textContaining('ljspeech'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(changes.single.modelId, 'en_US-ljspeech-medium');
    expect(container.read(languageModelChoicesProvider).choiceFor('en')?.modelId, 'en_US-ljspeech-medium');
    expect(container.read(languageModelChoicesProvider).choiceFor('pt'), isNull);
  });

  testWidgets('with nothing ready for the language the menu leads to Models on it', (tester) async {
    await _pump(tester, language: 'en', installed: const {'pt_BR-faber-medium'});
    await _open(tester);
    expect(find.byKey(const ValueKey('narration-missing')), findsOneWidget);
    expect(find.textContaining('English'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('reader-menu-open-models')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final screen = tester.widget<ModelsScreen>(find.byType(ModelsScreen));
    expect(screen.initialLanguage, 'en');
  });

  testWidgets('an unknown language keeps the whole catalog list', (tester) async {
    await _pump(tester, language: null);
    await _open(tester);
    final labels = _labels(tester);
    expect(labels.any((l) => l.contains('Faber')), isTrue);
    expect(find.byKey(const ValueKey('reader-menu-open-models')), findsNothing);
  });
}
