import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_models.dart';
import 'package:flutter_app/services/conversion/model_install/model_install_runner.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _modelId = 'pt_BR-faber-medium';

String _catalog() => jsonEncode({
  'schema_version': 3,
  'providers': [
    {
      'provider': 'piper',
      'runtime': 'piper',
      'targets': ['linux'],
      'capabilities': {'audio_bytes': true},
    },
  ],
  'entries': [
    {
      'identity': {
        'provider': 'piper',
        'runtime': 'piper',
        'model_id': _modelId,
        'model_revision': 'r1',
      },
      'compatibility': {'runtime_available': true, 'platforms': ['Linux']},
      'distribution': {'installable': true},
      'language_evidence': {'routing_tags': ['pt-BR']},
    },
  ],
});

class _InstallingConverter extends UnavailableEmbeddedConverter {
  final events = StreamController<ModelInstallEvent>();
  ModelInstallCancellation? cancellation;
  bool installed = false;

  @override
  Future<String> ttsModels() async => _catalog();

  @override
  Future<String?> ttsModelMetadata({required String modelId, required String root}) async =>
      installed ? '{}' : null;

  @override
  Stream<ModelInstallEvent> installTtsModelWithProgress({
    required String modelId,
    required String root,
    ModelInstallCancellation? cancellation,
  }) {
    this.cancellation = cancellation;
    return events.stream;
  }
}

ModelInstallEvent _event(ModelInstallStage stage, int done, {ModelInstallFailure? failure}) =>
    ModelInstallEvent(
      sequence: done,
      modelId: _modelId,
      stage: stage,
      bytesCompleted: done,
      bytesTotal: 100,
      failure: failure,
    );

Future<_InstallingConverter> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final converter = _InstallingConverter();
  addTearDown(() {
    if (!converter.events.isClosed) unawaited(converter.events.close());
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(converter),
        ttsModelRootProvider.overrideWith((_) => '/fixture-models'),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SingleChildScrollView(child: InstalledNarrationModelsCard())),
      ),
    ),
  );
  await _settle(tester);
  return converter;
}

/// Bounded pumping: a spinner that is still on screen would keep
/// `pumpAndSettle` waiting for its endless animation.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  final progress = find.byKey(const ValueKey('install-progress-$_modelId'));
  final cancel = find.byKey(const ValueKey('cancel-install-$_modelId'));

  testWidgets('a model row shows install progress in place and clears it when done', (tester) async {
    final converter = await _pump(tester);
    expect(progress, findsNothing);
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump();
    expect(progress, findsOneWidget, reason: 'indeterminate until the first event');
    expect(tester.widget<LinearProgressIndicator>(progress).value, isNull);

    converter.events.add(_event(ModelInstallStage.downloading, 25));
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(progress).value, 0.25);
    converter.events.add(_event(ModelInstallStage.downloading, 80));
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(progress).value, 0.8);

    converter.installed = true;
    converter.events.add(_event(ModelInstallStage.completed, 100));
    unawaited(converter.events.close());
    await _settle(tester);
    expect(progress, findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget, reason: 'now installed');
  });

  testWidgets('the row offers cancel while installing and it cancels the operation', (tester) async {
    final converter = await _pump(tester);
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump();
    expect(cancel, findsOneWidget);
    await tester.tap(cancel);
    expect(converter.cancellation?.isCancelled, isTrue);

    converter.events.add(_event(ModelInstallStage.cancelled, 10));
    unawaited(converter.events.close());
    await _settle(tester);
    expect(progress, findsNothing);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget, reason: 'still not installed');
  });

  testWidgets('a failed install clears the bar and tells the user why', (tester) async {
    final converter = await _pump(tester);
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pump();
    converter.events.add(
      _event(
        ModelInstallStage.failed,
        0,
        failure: const ModelInstallFailure(kind: 'insufficient_space', message: 'Not enough free space'),
      ),
    );
    unawaited(converter.events.close());
    await _settle(tester);
    expect(progress, findsNothing);
    expect(find.textContaining('Not enough free space'), findsOneWidget);
  });
}
