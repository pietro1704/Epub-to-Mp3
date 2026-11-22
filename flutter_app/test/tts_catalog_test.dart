import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/tts_catalog.dart';
import 'package:flutter_app/models/tts_preferences.dart';

void main() {
  test('stale catalogs cannot list or offer Piper Low models', () {
    final catalog = TtsCatalog.decode(jsonEncode({
      'schema_version': 3,
      'default_selection': {
        'version': 2,
        'provider': 'piper',
        'runtime': 'piper',
        'model_id': 'en_US-lessac-low',
        'model_revision': 'old',
      },
      'providers': [
        {
          'provider': 'piper',
          'runtime': 'piper',
          'targets': ['linux'],
          'capabilities': {'audio_bytes': true},
        },
      ],
      'entries': [
        _entry('en_US-lessac-low', 'piper', 'piper', 'old'),
        _entry('custom_x_low', 'piper', 'piper', 'old'),
        {
          ..._entry('legacy-id', 'piper', 'piper', 'old'),
          'presentation': {'quality': 'low'},
        },
        _entry('en_US-ljspeech-high', 'piper', 'piper', 'sha'),
      ],
    }));

    expect(catalog.models.map((entry) => entry['id']), ['en_US-ljspeech-high']);
    expect(
      catalog.selections(target: 'Linux').single.modelId,
      'en_US-ljspeech-high',
    );
    expect(catalog.defaultSelection, isNull);
  });

  test('manual Piper models require a ready probe for the requested revision', () {
    const id = 'en_US-lessac-low';
    const revision = 'catalog-revision';
    final listed = _entry(id, 'piper', 'piper', revision);
    final ready = {
      ...listed,
      'installation': {'state': 'installed', 'verified_revision': revision},
      'readiness': {'state': 'ready'},
      'selection': {'selectable': true},
    };
    String snapshot(Map<String, Object?> entry) => jsonEncode({
      'schema_version': 3,
      'providers': [
        {
          'provider': 'piper',
          'runtime': 'piper',
          'targets': ['linux'],
          'capabilities': {'audio_bytes': true},
        },
      ],
      'entries': [entry],
    });

    final automatic = TtsCatalog.decode(snapshot(ready));
    expect(automatic.manualModels(target: 'Linux'), isEmpty);
    expect(automatic.selections(target: 'Linux'), isEmpty);
    final catalog = TtsCatalog.decodeManual(snapshot(listed));
    final identity = catalog.manualModels(target: 'Linux').single;
    expect(identity.modelRevision, revision);
    expect(catalog.selections(target: 'Linux'), isEmpty);
    expect(catalog.recommendedPreferences.primary, TtsSelection.automaticPiper);
    expect(catalog.recommendedPreferences.secondary, TtsSelection.system);
    expect(() => catalog.confirmedManualModel(identity, target: 'Linux'), throwsStateError);
    for (final unexpected in [
      {...ready, 'installation': {'state': 'installed', 'verified_revision': 'stale'}},
      {...ready, 'readiness': {'state': 'unavailable'}},
      {...ready, 'identity': _entry(id, 'piper', 'piper', 'replaced')['identity']},
      {...ready, 'identity': _entry('unrelated-low', 'piper', 'piper', revision)['identity']},
    ]) {
      final probe = TtsCatalog.decodeManual(snapshot(unexpected));
      expect(() => probe.confirmedManualModel(identity, target: 'Linux'), throwsStateError);
    }

    final probe = TtsCatalog.decodeManual(snapshot(ready));
    final selected = probe.confirmedManualModel(identity, target: 'Linux');
    final preferences = const TtsPreferences.appDefaults().withPrimary(selected);
    final restored = TtsPreferences.fromJson(preferences.toJson()).withSupportedPiperQuality();
    expect(restored.primary.modelId, id);
    expect(restored.primary.hasManualPiperIdentity, isTrue);
    expect(restored.secondary?.toJson(), TtsSelection.system.toJson());
    final options = jsonDecode(restored.optionsJson()) as Map;
    final primary = options['tts_preferences']['primary'] as Map;
    expect(options['contract_version'], 2);
    expect(primary['session']['model_id'], id);
    expect(primary['session']['model_revision'], revision);
    expect(primary.containsKey('manual_model'), isFalse);
    expect(
      TtsPreferences(primary: selected, secondary: selected)
          .withSupportedPiperQuality().secondary,
      isNull,
    );
    final legacyLow = TtsSelection(engine: 'piper', modelId: id, session: identity);
    expect(
      TtsPreferences(primary: legacyLow).withSupportedPiperQuality().primary,
      TtsSelection.automaticPiper,
    );
  });

  test('catalog configuration adds distinct models on one runtime and survives capture', () {
    final catalog = TtsCatalog.decode(jsonEncode({'schema_version':3, 'providers': [
      {'provider':'provider', 'runtime':'runtime', 'targets':['linux','macos','android','ios','windows'], 'capabilities':{'audio_bytes':true}},
    ], 'entries': [
      for (final id in ['model-a', 'model-b'])
        _entry(id, 'provider', 'runtime', 'sha-$id'),
    ]}));
    final selections = catalog.selections();
    expect(selections.map((s) => s.modelId), ['model-a', 'model-b']);
    expect(selections[0].session!.runtime, 'runtime');
    final restored = TtsSelection.fromJson(jsonDecode(jsonEncode(selections[1].toJson())) as Map<String, dynamic>);
    expect(restored.session!.modelRevision, 'sha-model-b');
    expect(restored.toJson(), selections[1].toJson());
    final options = jsonDecode(TtsPreferences(primary: restored, secondary: TtsSelection.system).optionsJson()) as Map;
    expect(options['contract_version'], 2);
    expect(() => restored.session!.options['rate'] = '2', throwsUnsupportedError);
  });
  test('new jobs capture catalog revision without mutating legacy preferences', () {
    final catalog = TtsCatalog.decode(jsonEncode({'schema_version':3, 'providers':[
      {'provider':'piper','runtime':'piper','targets':['linux'], 'capabilities':{'audio_bytes':true}},
    ], 'entries':[
      _entry('pt_BR-faber-medium', 'piper', 'piper', 'sha'),
    ]}));
    const original = TtsPreferences.appDefaults(primary: TtsSelection.faber);
    final captured = catalog.captureNewPreferences(original, target:'Linux');
    expect(captured.primary.session!.modelRevision, 'sha');
    expect(captured.secondary!.engine, 'system');
    expect(original.primary.session, isNull);
    expect(catalog.captureNewPreferences(captured, target:'Linux').toJson(), captured.toJson());
  });
  test('rejects unknown contracts and retains legacy selections', () {
    expect(() => TtsCatalog.decode('{"version":3,"models":[]}'), throwsFormatException);
    expect(() => TtsCatalog.decode('[]'), throwsFormatException);
    expect(() => TtsCatalog.decode('{"version":2,"models":[]}'), throwsFormatException);
    expect(TtsSelection.fromJson({'engine':'system'}).session, isNull);
  });
  test('primary change clears an equivalent legacy secondary', () {
    final versioned = TtsCatalog.decode(jsonEncode({'schema_version':3, 'providers':[
      {'provider':'piper','runtime':'piper','targets':['linux'], 'capabilities':{'audio_bytes':true}},
    ], 'entries':[
      _entry('pt_BR-faber-medium', 'piper', 'piper', 'sha'),
    ]})).selections(target:'Linux').single;
    final preferences = TtsPreferences(primary: const TtsSelection(engine:'piper', modelId:'other'), secondary:TtsSelection.faber);
    expect(preferences.withPrimary(versioned).secondary, isNull);
    expect(preferences.withPrimary(versioned).primary.session!.modelRevision, 'sha');
    expect(preferences.secondary, TtsSelection.faber);
  });
  test('catalog filters unsupported runtime targets and old Android API', () {
    final catalog = TtsCatalog.decode(jsonEncode({'schema_version':3, 'android_api':28, 'providers':[
      {'provider':'piper','runtime':'piper','targets':['android'], 'capabilities':{'audio_bytes':true}},
    ],'entries':[
      _entry('compatible', 'piper', 'piper', 'sha', platforms: ['Android'], minimumAndroidApi: 28),
      _entry('too-new', 'piper', 'piper', 'sha', platforms: ['Android'], minimumAndroidApi: 29),
    ]}));
    expect(catalog.selections(target:'Android').map((s)=>s.modelId), ['compatible']);
    expect(catalog.selections(target:'Android', androidApi:27), isEmpty);
    expect(catalog.selections(target:'Linux'), isEmpty);
  });
}

Map<String, Object?> _entry(String id, String provider, String runtime, String revision,
    {List<String> platforms = const ['Android', 'Ios', 'Macos', 'Linux', 'Windows'],
    int? minimumAndroidApi}) => {
  'identity': {'model_id': id, 'provider': provider, 'runtime': runtime, 'model_revision': revision},
  'language_evidence': {'routing_tags': ['pt'], 'exact_tags': []},
  'compatibility': {'platforms': platforms, 'runtime_available': true, 'minimum_android_api': minimumAndroidApi},
  'distribution': {'artifacts': [], 'download_bytes': 0},
};
