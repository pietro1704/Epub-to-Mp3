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

    final primary = find.byKey(const ValueKey('narration-primary-row'));
    final secondary = find.byKey(const ValueKey('narration-secondary-row'));
    final lowLabel = find.text(_installedId);
    final toggle = container.read(showLowQualityModelsProvider.notifier);
    final defaults = TtsSelection.automaticPiper.modelId;
    TtsPreferences current() => AppSettings(prefs).ttsPreferences;

    Future<void> openVoices(Finder row) async {
      await tester.tap(find.descendant(of: row, matching: find.byType(ListTile)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('narration-engine-piper')));
      await tester.pumpAndSettle();
    }

    Future<void> dismiss() async {
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }

    expect(converter.catalogReads, 0);
    await openVoices(primary);
    expect(lowLabel, findsNothing);
    await dismiss();

    toggle.state = true;
    await tester.pumpAndSettle();
    expect(converter.catalogReads, 1);
    // The secondary voice never offers manual Low models (a single-voice
    // engine would be chosen on the spot, so only the engines are opened).
    await tester.tap(find.descendant(of: secondary, matching: find.byType(ListTile)));
    await tester.pumpAndSettle();
    expect(lowLabel, findsNothing);
    await dismiss();

    Future<void> selectLow() async {
      await openVoices(primary);
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
    expect(lowLabel, findsOneWidget, reason: 'the saved Low voice stays visible');
    await openVoices(primary);
    expect(
      tester
          .widget<ListTile>(find.ancestor(of: lowLabel.last, matching: find.byType(ListTile)))
          .enabled,
      isFalse,
    );
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
