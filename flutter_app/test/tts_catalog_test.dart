import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/tts_catalog.dart';
import 'package:flutter_app/models/tts_preferences.dart';

void main() {
  test('catalog configuration adds distinct models on one runtime and survives capture', () {
    final catalog = TtsCatalog.decode(jsonEncode({'version': 2, 'providers': [
      {'provider':'provider', 'runtime':'runtime', 'targets':['linux','macos','android','ios','windows'], 'capabilities':{'audio_bytes':true}},
    ], 'models': [
      for (final id in ['model-a', 'model-b'])
        {'id': id, 'engine': 'provider', 'runtime': 'runtime', 'revision': 'sha-$id', 'runtime_available': true},
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
    final catalog = TtsCatalog.decode(jsonEncode({'version':2, 'providers':[
      {'provider':'piper','runtime':'piper','targets':['linux'], 'capabilities':{'audio_bytes':true}},
    ], 'models':[
      {'id':'pt_BR-faber-medium','engine':'piper','runtime':'piper','revision':'sha','runtime_available':true},
    ]}));
    const original = TtsPreferences.appDefaults();
    final captured = catalog.captureNewPreferences(original, target:'Linux');
    expect(captured.primary.session!.modelRevision, 'sha');
    expect(captured.secondary!.engine, 'system');
    expect(original.primary.session, isNull);
    expect(catalog.captureNewPreferences(captured, target:'Linux').toJson(), captured.toJson());
  });
  test('rejects unknown contracts and retains legacy selections', () {
    expect(() => TtsCatalog.decode('{"version":3,"models":[]}'), throwsFormatException);
    expect(TtsCatalog.decode('[]').selections(), isEmpty);
    expect(TtsSelection.fromJson({'engine':'system'}).session, isNull);
  });
  test('primary change clears an equivalent legacy secondary', () {
    final versioned = TtsCatalog.decode(jsonEncode({'version':2, 'providers':[
      {'provider':'piper','runtime':'piper','targets':['linux'], 'capabilities':{'audio_bytes':true}},
    ], 'models':[
      {'id':'pt_BR-faber-medium','engine':'piper','runtime':'piper','revision':'sha','runtime_available':true},
    ]})).selections(target:'Linux').single;
    final preferences = TtsPreferences(primary: const TtsSelection(engine:'piper', modelId:'other'), secondary:TtsSelection.faber);
    expect(preferences.withPrimary(versioned).secondary, isNull);
    expect(preferences.withPrimary(versioned).primary.session!.modelRevision, 'sha');
    expect(preferences.secondary, TtsSelection.faber);
  });
  test('catalog filters unsupported runtime targets and old Android API', () {
    final catalog = TtsCatalog.decode(jsonEncode({'version':2, 'android_api':28, 'providers':[
      {'provider':'piper','runtime':'piper','targets':['android'], 'capabilities':{'audio_bytes':true}},
    ],'models':[
      {'id':'compatible','engine':'piper','runtime':'piper','revision':'sha','runtime_available':true,'platforms':['Android'],'minimum_android_api':28},
      {'id':'too-new','engine':'piper','runtime':'piper','revision':'sha','runtime_available':true,'platforms':['Android'],'minimum_android_api':29},
    ]}));
    expect(catalog.selections(target:'Android').map((s)=>s.modelId), ['compatible']);
    expect(catalog.selections(target:'Android', androidApi:27), isEmpty);
    expect(catalog.selections(target:'Linux'), isEmpty);
  });
}
