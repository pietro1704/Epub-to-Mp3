import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/models_language_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/conversion/voice_audition.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _entry(String provider, String id) => {
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
  'language_evidence': {
    'routing_tags': ['pt-BR'],
  },
};

class _Converter extends UnavailableEmbeddedConverter {
  @override
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages() async => const [
    TtsCatalogLanguage(tag: 'pt', modelCount: 2),
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
      _entry('piper', 'pt_BR-faber-medium'),
      _entry('edge', 'edge-pt'),
    ],
  });

  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => '{}';
}

Future<List<String>> _pump(WidgetTester t, {required bool online}) async {
  final rendered = <String>[];
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (online) {
    await AppSettings(prefs)
        .setTtsPreferences(const TtsPreferences(allowOnlineFallback: true));
  }
  final audition = VoiceAudition(
    render: (options, text, output, cancel) async =>
        rendered.add('$text|$options'),
    play: (_) async {},
    stopPlayback: () async {},
  );
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(_Converter()),
        ttsModelRootProvider.overrideWith((_) => '/models'),
        systemVoiceLanguagesProvider.overrideWith((_) async => const []),
        voiceAuditionProvider.overrideWithValue(audition),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ModelsLanguageScreen(language: 'pt'),
      ),
    ),
  );
  await t.pumpAndSettle();
  return rendered;
}

void main() {
  testWidgets('an installed Piper voice has a sample button that plays it', (
    t,
  ) async {
    final rendered = await _pump(t, online: false);
    await t.tap(find.byKey(const ValueKey('voice-sample-pt_BR-faber-medium')));
    await t.pumpAndSettle();
    expect(rendered, hasLength(1));
    expect(rendered.single, contains('amostra da voz'));
    expect(rendered.single, contains('pt_BR-faber-medium'));
  });

  testWidgets(
    'an online voice without consent shows the notice and never renders',
    (t) async {
      final rendered = await _pump(t, online: false);
      await t.tap(find.byKey(const ValueKey('voice-sample-edge-pt')));
      await t.pumpAndSettle();
      expect(rendered, isEmpty);
      expect(
        find.text(
          'Turn on “Allow online fallback” in Settings to use online voices',
        ),
        findsWidgets,
      );
    },
  );

  testWidgets('an online voice renders its sample once consent is on', (
    t,
  ) async {
    final rendered = await _pump(t, online: true);
    await t.tap(find.byKey(const ValueKey('voice-sample-edge-pt')));
    await t.pumpAndSettle();
    expect(rendered, hasLength(1));
  });
}
