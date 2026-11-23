import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/language_model_choices.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/models_screen.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_models.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_runner.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _entry(String provider, String id, List<String> tags) => {
  'identity': {'provider': provider, 'runtime': provider, 'model_id': id, 'model_revision': 'r1'},
  'compatibility': {'runtime_available': true, 'platforms': ['Linux']},
  'distribution': {'installable': true, 'download_bytes': 1000},
  'language_evidence': {'routing_tags': tags},
};

String _catalog() => jsonEncode({
  'schema_version': 3,
  'providers': [
    {'provider': 'piper', 'runtime': 'piper', 'targets': ['linux'], 'capabilities': {}},
    {'provider': 'edge', 'runtime': 'edge', 'targets': ['linux'], 'capabilities': {}},
  ],
  'entries': [
    _entry('piper', 'pt_BR-faber-medium', ['pt-BR']),
    _entry('piper', 'pt_PT-tugao-medium', ['pt-PT']),
    _entry('piper', 'en_US-lessac-medium', ['en-US']),
    _entry('edge', 'edge-pt', ['pt-BR']),
  ],
});

class _ModelsConverter extends UnavailableEmbeddedConverter {
  _ModelsConverter({Set<String> installed = const {'pt_BR-faber-medium'}}) : installed = {...installed};
  final Set<String> installed;
  final installs = <String>[];
  StreamController<ModelInstallEvent>? events;

  @override
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages() async => const [
    TtsCatalogLanguage(tag: 'en', modelCount: 1),
    TtsCatalogLanguage(tag: 'pt', modelCount: 3),
  ];

  @override
  Future<String> ttsModels() async => _catalog();

  @override
  Future<String?> ttsModelMetadata({required String modelId, required String root}) async =>
      installed.contains(modelId) ? '{}' : null;

  @override
  Stream<ModelInstallEvent> installTtsModelWithProgress({
    required String modelId,
    required String root,
    ModelInstallCancellation? cancellation,
  }) {
    installs.add(modelId);
    events = StreamController<ModelInstallEvent>();
    return events!.stream;
  }
}

ModelInstallEvent _event(ModelInstallStage stage, int done, [ModelInstallFailure? failure]) => ModelInstallEvent(
  sequence: done,
  modelId: 'm',
  stage: stage,
  bytesCompleted: done,
  bytesTotal: 100,
  failure: failure,
);

Future<(_ModelsConverter, SharedPreferences)> _pump(
  WidgetTester tester, {
  _ModelsConverter? converter,
  Map<String, Object> prefsData = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefsData);
  final prefs = await SharedPreferences.getInstance();
  final fake = converter ?? _ModelsConverter();
  addTearDown(() {
    final controller = fake.events;
    if (controller != null && !controller.isClosed) unawaited(controller.close());
  });
  // The screen now also hosts the narration settings, so it needs room.
  tester.view.physicalSize = const Size(1000, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(fake),
        ttsModelRootProvider.overrideWith((_) => '/fixture-models'),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ModelsScreen(),
      ),
    ),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (fake, prefs);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

LanguageModelChoices _stored(SharedPreferences prefs) =>
    LanguageModelChoices.parse(prefs.getString(LanguageModelChoices.storageKey));

void main() {
  testWidgets('lists the catalog languages by their own name, automatic by default', (tester) async {
    await _pump(tester);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Português'), findsOneWidget);
    expect(find.textContaining('Automatic · 3 models'), findsOneWidget);
    expect(find.textContaining('Automatic · 1 model'), findsOneWidget);
  });

  testWidgets('an installed model is chosen with one tap and persisted', (tester) async {
    final (_, prefs) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('language-pt')));
    await _settle(tester);
    // Only models that serve Portuguese are listed under it.
    expect(find.byKey(const ValueKey('model-pt-pt_BR-faber-medium')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-pt-en_US-lessac-medium')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('model-pt-pt_BR-faber-medium')));
    await _settle(tester);
    expect(_stored(prefs).choiceFor('pt')?.modelId, 'pt_BR-faber-medium');
    expect(find.textContaining('pt_BR-faber-medium · 3 models'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('model-pt-automatic')));
    await _settle(tester);
    expect(_stored(prefs).choiceFor('pt'), isNull, reason: 'Automatic clears the choice');
  });

  testWidgets('tapping a model that is not installed downloads it with progress, then chooses it', (tester) async {
    final (converter, prefs) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('language-pt')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('model-pt-pt_PT-tugao-medium')));
    await tester.pump();
    expect(converter.installs, ['pt_PT-tugao-medium']);
    final bar = find.byKey(const ValueKey('models-progress-pt_PT-tugao-medium'));
    expect(bar, findsOneWidget);
    expect(_stored(prefs).choiceFor('pt'), isNull, reason: 'not chosen until installed');

    converter.events!.add(_event(ModelInstallStage.downloading, 40));
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0.4);

    converter.installed.add('pt_PT-tugao-medium');
    converter.events!.add(_event(ModelInstallStage.completed, 100));
    unawaited(converter.events!.close());
    await _settle(tester);
    expect(bar, findsNothing);
    expect(_stored(prefs).choiceFor('pt')?.modelId, 'pt_PT-tugao-medium');
  });

  testWidgets('cancelling a download leaves the choice untouched', (tester) async {
    final (converter, prefs) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('language-pt')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('model-pt-pt_PT-tugao-medium')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('models-cancel-pt_PT-tugao-medium')));
    converter.events!.add(_event(ModelInstallStage.cancelled, 10));
    unawaited(converter.events!.close());
    await _settle(tester);
    expect(find.byKey(const ValueKey('models-progress-pt_PT-tugao-medium')), findsNothing);
    expect(_stored(prefs).choiceFor('pt'), isNull);
  });

  testWidgets('a failed download shows why and chooses nothing', (tester) async {
    final (converter, prefs) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('language-pt')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('model-pt-pt_PT-tugao-medium')));
    await tester.pump();
    converter.events!.add(
      _event(ModelInstallStage.failed, 0, const ModelInstallFailure(kind: 'insufficient_space', message: 'Not enough free space')),
    );
    unawaited(converter.events!.close());
    await _settle(tester);
    expect(find.byKey(const ValueKey('models-error')), findsOneWidget);
    expect(find.text('Not enough free space'), findsOneWidget);
    expect(_stored(prefs).choiceFor('pt'), isNull);
  });

  testWidgets('online voices are dimmed without consent and usable with it', (tester) async {
    final (converter, prefs) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('language-pt')));
    await _settle(tester);
    final online = find.byKey(const ValueKey('model-pt-edge-pt'));
    expect(find.text('Online'), findsOneWidget);
    expect(find.textContaining('Allow online fallback'), findsWidgets);
    await tester.tap(online);
    await _settle(tester);
    expect(_stored(prefs).choiceFor('pt'), isNull, reason: 'no consent, no choice');
    expect(converter.installs, isEmpty);

    // With consent saved, Edge is selectable and needs no download.
    const preferences = TtsPreferences(
      primary: TtsSelection.faber,
      secondary: TtsSelection(engine: 'system'),
      allowOnlineFallback: true,
    );
    final (_, prefs2) = await _pump(tester, prefsData: {'ttsPreferences': jsonEncode(preferences.toJson())});
    await tester.tap(find.byKey(const ValueKey('language-pt')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('model-pt-edge-pt')));
    await _settle(tester);
    expect(_stored(prefs2).choiceFor('pt')?.engine, 'edge');
  });

  testWidgets('a stored choice is shown as selected after relaunch', (tester) async {
    const stored = LanguageModelChoices({'en': TtsSelection(engine: 'piper', modelId: 'en_US-lessac-medium')});
    await _pump(tester, prefsData: {LanguageModelChoices.storageKey: stored.encode()});
    expect(find.textContaining('en_US-lessac-medium · 1 model'), findsOneWidget);
  });

  testWidgets('an unavailable converter shows a message instead of an empty screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          embeddedConverterProvider.overrideWithValue(UnavailableEmbeddedConverter()),
          ttsModelRootProvider.overrideWith((_) => '/fixture-models'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const ModelsScreen(),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('The model list could not be loaded'), findsOneWidget);
  });

  testWidgets('Settings offers one Models row that opens the screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          embeddedConverterProvider.overrideWithValue(_ModelsConverter()),
          ttsModelRootProvider.overrideWith((_) => '/fixture-models'),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );
    await _settle(tester);
    final row = find.byKey(const ValueKey('settings-models-row'));
    expect(row, findsOneWidget);
    await tester.ensureVisible(row);
    await tester.tap(row);
    await _settle(tester);
    expect(find.byType(ModelsScreen), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
  });
}
