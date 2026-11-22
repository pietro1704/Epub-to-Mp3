import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _lowModelId = 'pt_BR-edresson-low';
const _regularModelId = 'pt_BR-faber-medium';
const _revision = 'fixture-revision';
const _root = '/fixture/tts-models';

class _ModelConverter extends UnavailableEmbeddedConverter
    implements ManualTtsModelCatalog {
  final installs = <String>[];
  final removals = <String>[];
  int manualCatalogCalls = 0;
  bool installed = false;
  bool manualAvailable = true;

  Map<String, Object> _entry(String modelId) => {
    'identity': {
      'model_id': modelId,
      'provider': 'piper',
      'runtime': 'piper',
      'model_revision': _revision,
    },
    'presentation': {'quality': modelId == _lowModelId ? 'low' : 'medium'},
    'compatibility': {
      'runtime_available': true,
      'platforms': ['Linux', 'Windows', 'Android'],
    },
    'language_evidence': {
      'routing_tags': ['pt-BR'],
    },
    'distribution': {
      'installable': true,
      'artifacts': [
        {'filename': 'fixture.onnx'},
      ],
      'download_bytes': 120,
    },
    'installation': installed && modelId == _lowModelId
        ? {'state': 'installed', 'verified_revision': _revision}
        : {'state': 'missing'},
  };

  String _catalog(List<String> modelIds) => jsonEncode({
    'schema_version': 3,
    'entries': modelIds.map(_entry).toList(),
    'providers': [
      {
        'provider': 'piper',
        'runtime': 'piper',
        'targets': ['linux', 'windows', 'android'],
        'capabilities': {'audio_bytes': true},
      },
    ],
  });

  @override
  Future<String> ttsModels() async => _catalog([_regularModelId]);

  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => null;

  @override
  Future<String> ttsManualModels({required String root}) async {
    expect(root, _root);
    manualCatalogCalls++;
    if (!manualAvailable) throw EmbeddedConverterUnavailable();
    return _catalog([_lowModelId, _regularModelId]);
  }

  @override
  Future<String> probeTtsModel({
    required String modelId,
    required String root,
    String? language,
  }) async => throw StateError('The downloads card must not probe a model');

  @override
  Future<String> installTtsModelFromCatalog({
    required String modelId,
    required String root,
  }) async {
    expect(root, _root);
    installs.add(modelId);
    installed = true;
    return '$root/$modelId';
  }

  @override
  Future<bool> removeTtsModel({
    required String modelId,
    required String root,
  }) async {
    expect(root, _root);
    removals.add(modelId);
    installed = false;
    return true;
  }
}

Future<void> _pump(WidgetTester tester, _ModelConverter converter) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        embeddedConverterProvider.overrideWithValue(converter),
        ttsModelRootProvider.overrideWith((ref) async => _root),
      ],
      child: const MaterialApp(
        locale: Locale('pt'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: InstalledNarrationModelsCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _lowModelAction(IconData icon) => find.descendant(
  of: find.ancestor(
    of: find.text(_lowModelId),
    matching: find.byType(ListTile),
  ),
  matching: find.byIcon(icon),
);

void main() {
  testWidgets('Low models require explicit download and removal', (
    tester,
  ) async {
    final converter = _ModelConverter();
    await _pump(tester, converter);
    final switchTile = find.widgetWithText(
      SwitchListTile,
      'Mostrar qualidade baixa',
    );
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse);
    expect(find.text(_regularModelId), findsOneWidget);
    expect(find.text(_lowModelId), findsNothing);
    expect(converter.manualCatalogCalls, 0);

    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(find.text(_regularModelId), findsOneWidget);
    expect(find.text(_lowModelId), findsOneWidget);
    expect(converter.manualCatalogCalls, 1);
    expect(converter.installs, isEmpty);

    await tester.tap(_lowModelAction(Icons.download_outlined));
    await tester.pumpAndSettle();
    expect(converter.installs, [_lowModelId]);
    expect(_lowModelAction(Icons.delete_outline), findsOneWidget);

    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    expect(find.text(_lowModelId), findsNothing);
    expect(converter.installed, isTrue);
    expect(converter.removals, isEmpty);

    await tester.tap(switchTile);
    await tester.pumpAndSettle();
    await tester.tap(_lowModelAction(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(converter.removals, [_lowModelId]);
    expect(_lowModelAction(Icons.download_outlined), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('Refresh retries manual catalog errors independently', (
    tester,
  ) async {
    final converter = _ModelConverter()..manualAvailable = false;
    await _pump(tester, converter);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
      find.text('Não foi possível preparar este modelo de narração.'),
      findsOneWidget,
    );
    expect(find.text(_regularModelId), findsOneWidget);

    converter.manualAvailable = true;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.text(_lowModelId), findsOneWidget);
    expect(converter.installs, isEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));
}
