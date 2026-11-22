import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _installedId = 'pt_BR-edresson-low';
const _missingId = 'en_US-lessac-low';
const _revision = 'test-model-revision';

Map<String, Object> _entry(
  String modelId, {
  String revision = _revision,
  bool installed = true,
  bool ready = false,
}) => {
  'identity': {
    'provider': 'piper',
    'runtime': 'piper',
    'model_id': modelId,
    'model_revision': revision,
  },
  'compatibility': {
    'runtime_available': true,
    'platforms': ['Linux'],
  },
  'distribution': {'installable': true},
  'language_evidence': {
    'routing_tags': ['pt-BR'],
  },
  'installation': {
    'state': installed ? 'installed' : 'missing',
    if (installed) 'verified_revision': revision,
  },
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

class _ManualConverter extends UnavailableEmbeddedConverter
    implements ManualTtsModelCatalog {
  final probes = <Completer<String>>[];
  final probeArguments = <(String, String, String?)>[];
  int catalogReads = 0;

  @override
  Future<String> ttsModels() async => _snapshot([]);

  @override
  Future<String> ttsManualModels({required String root}) async {
    catalogReads++;
    return _snapshot([
      _entry(_installedId),
      _entry(_missingId, installed: false),
    ]);
  }

  @override
  Future<String> probeTtsModel({
    required String modelId,
    required String root,
    String? language,
  }) {
    probeArguments.add((modelId, root, language));
    final probe = Completer<String>();
    probes.add(probe);
    return probe.future;
  }
}

void main() {
  testWidgets('only a matching current Low probe changes primary narration', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final converter = _ManualConverter();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(converter),
        ttsModelRootProvider.overrideWith((_) => '/fixture-tts-models'),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: VoiceSelectionSettings()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final primary = find.byType(DropdownButtonFormField<String>).first;
    final secondary = find.byType(DropdownButtonFormField<String>).last;
    final lowLabel = find.text('Piper · $_installedId');
    final toggle = container.read(showLowQualityModelsProvider.notifier);
    final defaults = TtsSelection.automaticPiper.modelId;
    TtsPreferences current() => AppSettings(prefs).ttsPreferences;

    expect(converter.catalogReads, 0);
    await tester.tap(primary);
    await tester.pumpAndSettle();
    expect(lowLabel, findsNothing);
    await tester.tapAt(const Offset(5, 550));
    await tester.pumpAndSettle();

    toggle.state = true;
    await tester.pumpAndSettle();
    expect(converter.catalogReads, 1);
    await tester.tap(secondary);
    await tester.pumpAndSettle();
    expect(lowLabel, findsNothing);
    await tester.tapAt(const Offset(5, 550));
    await tester.pumpAndSettle();

    Future<void> selectLow() async {
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(find.textContaining(_missingId), findsNothing);
      await tester.tap(lowLabel);
      await tester.pumpAndSettle();
      expect(current().primary.modelId, defaults);
      expect(lowLabel, findsNothing);
    }

    await selectLow();
    expect(converter.probeArguments.single, (
      _installedId,
      '/fixture-tts-models',
      'pt-BR',
    ));
    converter.probes[0].complete(
      _snapshot([_entry(_installedId, revision: 'replacement', ready: true)]),
    );
    await tester.pumpAndSettle();
    expect(current().primary.modelId, defaults);
    final localizations = AppLocalizations.of(tester.element(primary))!;
    expect(find.text(localizations.ttsManualModelUnavailable), findsOneWidget);
    ScaffoldMessenger.of(tester.element(primary)).removeCurrentSnackBar();

    await selectLow();
    toggle.state = false;
    toggle.state = true;
    await tester.pumpAndSettle();
    converter.probes[1].complete(
      _snapshot([_entry(_installedId, ready: true)]),
    );
    await tester.pumpAndSettle();
    expect(current().primary.modelId, defaults);

    await selectLow();
    converter.probes[2].complete(
      _snapshot([_entry(_installedId, ready: true)]),
    );
    await tester.pumpAndSettle();
    expect(current().primary.modelId, _installedId);
    expect(current().primary.session?.modelRevision, _revision);
    expect(current().primary.hasManualPiperIdentity, isTrue);
    expect(current().secondary?.engine, 'system');

    toggle.state = false;
    await tester.pumpAndSettle();
    expect(lowLabel, findsOneWidget);
    final choices = tester
        .widget<DropdownButton<String>>(
          find.descendant(
            of: primary,
            matching: find.byType(DropdownButton<String>),
          ),
        )
        .items!;
    expect(
      choices
          .where((item) => item.value!.contains(_installedId))
          .single
          .enabled,
      isFalse,
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
