import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/language_model_choices.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/screens/models_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Show low-quality voices": with it on, the language page also lists the Piper Low voices, and
/// choosing one stores the choice with its catalog revision (Rust accepts a Low voice only then).
const _lowId = 'pt_BR-edresson-low';
const _revision = 'test-model-revision';

Map<String, Object> _entry({bool ready = false}) => {
  'identity': {
    'provider': 'piper',
    'runtime': 'piper',
    'model_id': _lowId,
    'model_revision': _revision,
  },
  'compatibility': {
    'runtime_available': true,
    'platforms': ['Linux'],
  },
  'distribution': {'installable': true, 'download_bytes': 20000000},
  'language_evidence': {
    'routing_tags': ['pt-BR'],
  },
  'presentation': {'quality': 'low'},
  'installation': {'state': 'installed', 'verified_revision': _revision},
  'readiness': {'state': ready ? 'ready' : 'unknown'},
  'selection': {'selectable': ready},
};

String _snapshot(List<Map<String, Object>> entries) => jsonEncode({
  'schema_version': 3,
  'providers': [
    {
      'provider': 'piper',
      'runtime': 'piper',
      'targets': ['linux'],
      'capabilities': {'audio_bytes': true},
    },
  ],
  'entries': entries,
});

class _Converter extends UnavailableEmbeddedConverter
    implements ManualTtsModelCatalog {
  final probes = <String>[];
  @override
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages() async => const [
    TtsCatalogLanguage(tag: 'pt', modelCount: 1),
  ];
  @override
  Future<String> ttsModels() async => _snapshot([]);
  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => '{}';
  @override
  Future<String> ttsManualModels({required String root}) async =>
      _snapshot([_entry()]);
  @override
  Future<String> probeTtsModel({
    required String modelId,
    required String root,
    String? language,
  }) async {
    probes.add(modelId);
    return _snapshot([_entry(ready: true)]);
  }
}

Future<(_Converter, SharedPreferences)> _pump(
  WidgetTester tester, {
  required bool showLow,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final converter = _Converter();
  tester.view.physicalSize = const Size(1000, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(converter),
        ttsModelRootProvider.overrideWith((_) => '/fixture-models'),
        systemVoiceLanguagesProvider.overrideWith(
          (_) async => const <String>[],
        ),
        showLowQualityModelsProvider.overrideWith((_) => showLow),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ModelsScreen(initialLanguage: 'pt'),
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (converter, prefs);
}

void main() {
  testWidgets('without the switch the language page lists no Low voice', (
    tester,
  ) async {
    try {
      await _pump(tester, showLow: false);
      expect(find.byKey(const ValueKey('model-pt-$_lowId')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'with the switch the language page lists the installed Low voice and choosing it keeps its revision',
    (tester) async {
      try {
        final (converter, prefs) = await _pump(tester, showLow: true);
        await _chooseLowVoice(tester, converter, prefs);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

Future<void> _chooseLowVoice(
  WidgetTester tester,
  _Converter converter,
  SharedPreferences prefs,
) async {
  {
    expect(find.text('Piper · low quality'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('model-pt-$_lowId')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(converter.probes, [
      _lowId,
    ], reason: 'the voice is probed before it is chosen');
    final choice = LanguageModelChoices.parse(
      prefs.getString(LanguageModelChoices.storageKey),
    ).choiceFor('pt');
    expect(choice?.modelId, _lowId);
    expect(
      choice?.session?.modelRevision,
      _revision,
      reason: 'Rust accepts a Low voice only with its revision',
    );
  }
}
