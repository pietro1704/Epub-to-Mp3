import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/narration_plan.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decoding the contract', () {
    test('catalog languages', () {
      final languages = TtsCatalogLanguage.parseAll(
        '{"schema_version":1,"languages":[{"tag":"en","model_count":4},'
        '{"tag":"pt","routing_tags":["pt","pt-BR"],"model_count":3}]}',
      );
      expect(languages.map((l) => l.tag), ['en', 'pt']);
      expect(languages.last.modelCount, 3);
      expect(languages.last.routingTags, ['pt', 'pt-BR']);
      expect(languages.first.routingTags, isEmpty);
    });

    test('a selected resolution carries the selection and its source', () {
      final resolution = LanguageModelResolution.parse(
        '{"schema_version":1,"book_language":"pt-BR","status":"selected",'
        '"selection":{"engine":"piper","model_id":"pt_BR-faber-medium","voice":null},'
        '"source":"primary","reasons":["per_language_choice:model_not_installed"]}',
      );
      expect(resolution.status, LanguageModelStatus.selected);
      expect(resolution.selection?.modelId, 'pt_BR-faber-medium');
      expect(resolution.source, 'primary');
      expect(resolution.reasons, ['per_language_choice:model_not_installed']);
      expect(resolution.missing, isNull);
    });

    test('a missing model lists ranked suggestions and no selection', () {
      final resolution = LanguageModelResolution.parse(
        '{"schema_version":1,"book_language":"de","status":"missing_model","reasons":[],'
        '"missing":{"language":"de","suggested":[{"model_id":"de_DE-thorsten-medium","quality":"medium","download_bytes":63000000}]}}',
      );
      expect(resolution.status, LanguageModelStatus.missingModel);
      expect(resolution.selection, isNull);
      expect(resolution.missing?.language, 'de');
      expect(resolution.missing?.suggested.single.downloadBytes, 63000000);
    });

    test('a status from a newer Rust is unknown, never selected', () {
      final resolution = LanguageModelResolution.parse(
        '{"book_language":"pt","status":"something_new"}',
      );
      expect(resolution.status, LanguageModelStatus.unknown);
      expect(resolution.selection, isNull);
    });

    test('book language: a confirmed and an unconfirmed analysis', () {
      final confirmed = BookLanguageAnalysis.parse(
        '{"schema_version":1,"declared":"en","confirmed":"pt-BR","languages":["pt-BR"],'
        '"samples_examined":8,"inconclusive_samples":1,"detector":"whatlang-0.18/book-consensus-v1"}',
      );
      expect(confirmed.confirmed, 'pt-BR');
      expect(confirmed.declared, 'en');
      expect(confirmed.inconclusiveSamples, 1);
      final unconfirmed = BookLanguageAnalysis.parse(
        '{"declared":"en","confirmed":null,"languages":["en","fr"],"samples_examined":8,"inconclusive_samples":2}',
      );
      expect(unconfirmed.confirmed, isNull, reason: 'the client must show the language picker');
      expect(unconfirmed.languages, ['en', 'fr']);
    });
  });

  test('the request serializes exactly the contract fields', () {
    final request = LanguageModelRequest(
      bookLanguage: 'pt-BR',
      platform: 'Linux',
      perLanguageChoices: const {'pt': TtsSelection.faber},
      primary: TtsSelection.faber,
      allowOnlineFallback: true,
      installedModelIds: const ['pt_BR-faber-medium'],
      systemVoices: const ['pt-BR'],
    );
    final json = request.toJson();
    expect(json['schema_version'], 1);
    expect(json['book_language'], 'pt-BR');
    expect(json['platform'], 'Linux');
    expect(json['allow_online_fallback'], isTrue);
    expect(json['allow_automatic_system_voice_fallback'], isTrue, reason: 'on by default');
    expect(json['per_language_choices']['pt']['model_id'], 'pt_BR-faber-medium');
    expect(json['primary']['engine'], 'piper');
    expect(json['installed_model_ids'], ['pt_BR-faber-medium']);
    expect(json.containsKey('android_api'), isFalse);
    expect(const LanguageModelRequest(bookLanguage: 'en', platform: 'Android', androidApi: 34).toJson()['android_api'], 34);
    expect(() => jsonEncode(json), returnsNormally);
  });

  group('Android channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('language_model_test');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'ttsCatalogLanguages' => '{"schema_version":1,"languages":[{"tag":"pt","model_count":2}]}',
          'ttsResolveLanguageModel' => '{"book_language":"pt-BR","status":"system_fallback","selection":{"engine":"system"},"source":"system"}',
          'bookLanguage' => '{"declared":"pt","confirmed":"pt-BR","languages":["pt-BR"]}',
          'bookNarrationPlan' => '{"schema_version":1,"decision":{"language":"pt-BR","source":"user_correction","preselect":null,"declared_conflict":null},'
              '"main":{"schema_version":1,"book_language":"pt-BR","status":"selected","source":"book_voice","selection":{"engine":"piper","model_id":"pt_BR-cadu-medium"},"reasons":[]},'
              '"language_voices":{},"main_missing":false,"notify_missing":[],"needs_language_question":false}',
          _ => null,
        };
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    });

    test('the three calls reach the native methods with their arguments', () async {
      final converter = AndroidEmbeddedConverter(channel: channel);
      expect((await converter.ttsCatalogLanguages()).single.tag, 'pt');
      final resolution = await converter.resolveLanguageModel(
        const LanguageModelRequest(bookLanguage: 'pt-BR', platform: 'Android', androidApi: 34),
      );
      expect(resolution.status, LanguageModelStatus.systemFallback);
      expect(resolution.selection?.engine, 'system');
      expect((await converter.bookLanguage('/books/a.epub')).confirmed, 'pt-BR');

      expect(calls.map((c) => c.method), ['ttsCatalogLanguages', 'ttsResolveLanguageModel', 'bookLanguage']);
      final request = jsonDecode((calls[1].arguments as Map)['request'] as String) as Map;
      expect(request['book_language'], 'pt-BR');
      expect(request['android_api'], 34);
      expect((calls[2].arguments as Map)['path'], '/books/a.epub');
    });

    test('the narration plan reaches the native method as one request JSON and decodes the answer', () async {
      final converter = AndroidEmbeddedConverter(channel: channel);
      expect((converter as NarrationPlanCapable).supportsNarrationPlan, isTrue);
      final plan = await (converter as NarrationPlanCapable).bookNarrationPlan(
        const NarrationPlanRequest(userCorrection: 'pt-BR', platform: 'Android', androidApi: 34),
      );
      expect(plan.decision.source, NarrationDecisionSource.userCorrection);
      expect(plan.main?.source, 'book_voice');
      expect(plan.main?.selection?.modelId, 'pt_BR-cadu-medium');
      expect(calls.single.method, 'bookNarrationPlan');
      final request = jsonDecode((calls.single.arguments as Map)['request'] as String) as Map;
      expect(request['user_correction'], 'pt-BR');
      expect(request['android_api'], 34);
    });
  });
}
