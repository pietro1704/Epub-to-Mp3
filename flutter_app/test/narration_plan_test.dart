import 'dart:convert';

import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/narration_plan.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rust's narration plan (`converter_book_narration_plan_json_v1`, R2): one pure answer before
/// any audio. These types only carry the request and decode the answer.
const _analysis = {
  'declared': 'en',
  'confirmed': 'pt',
  'languages': ['fr', 'pt'],
  'samples_examined': 32,
  'inconclusive_samples': 0,
  'detector': 'whatlang',
  'profile': {
    'class': 'bilingual',
    'primary': 'pt',
    'languages': [
      {'language': 'pt', 'chars': 9000, 'fraction': 0.9, 'longest_section_chars': 9000, 'role': 'main'},
      {'language': 'fr', 'chars': 1000, 'fraction': 0.1, 'longest_section_chars': 1600, 'role': 'significant'},
    ],
    'incidental': [],
  },
};

void main() {
  test('the request carries the analysis and profile exactly as Rust produced them', () {
    final analysis = BookLanguageAnalysis.fromJson(Map<String, dynamic>.from(_analysis));
    final request = NarrationPlanRequest(
      userCorrection: 'pt-BR',
      declared: 'en',
      analysis: analysis,
      bookVoice: const TtsSelection(engine: 'piper', modelId: 'pt_BR-cadu-medium'),
      perLanguageChoices: const {'fr': TtsSelection(engine: 'piper', modelId: 'fr_FR-siwis-medium')},
      primary: TtsSelection.automaticPiper,
      allowOnlineFallback: true,
      installedModelIds: const ['pt_BR-cadu-medium'],
      systemVoices: const ['pt-BR'],
      platform: 'Android',
      androidApi: 34,
    );
    final json = jsonDecode(jsonEncode(request.toJson())) as Map<String, dynamic>;
    expect(json['schema_version'], 1);
    expect(json['user_correction'], 'pt-BR');
    expect(json['declared'], 'en');
    expect(json['analysis']['confirmed'], 'pt');
    // The profile's per-language details (chars, longest section, role) survive the round trip.
    expect(json['profile']['languages'][1]['role'], 'significant');
    expect(json['profile']['languages'][1]['longest_section_chars'], 1600);
    expect(json['book_voice']['model_id'], 'pt_BR-cadu-medium');
    expect(json['per_language_choices']['fr']['model_id'], 'fr_FR-siwis-medium');
    expect(json['installed_model_ids'], ['pt_BR-cadu-medium']);
    expect(json['platform'], 'Android');
    expect(json['android_api'], 34);
    expect(json['allow_automatic_system_voice_fallback'], isTrue);
  });

  test('the plan decodes the decision, the main voice, the other languages and the notices', () {
    final plan = NarrationPlan.parse(jsonEncode({
      'schema_version': 1,
      'decision': {'language': 'pt', 'source': 'profile', 'preselect': null, 'declared_conflict': 'en'},
      'main': {
        'schema_version': 1,
        'book_language': 'pt',
        'status': 'selected',
        'source': 'book_voice',
        'selection': {'engine': 'piper', 'model_id': 'pt_BR-cadu-medium'},
        'reasons': [],
      },
      'language_voices': {'fr': {'engine': 'piper', 'model_id': 'fr_FR-siwis-medium'}},
      'main_missing': false,
      'notify_missing': [
        {'language': 'la', 'role': 'significant'},
      ],
      'needs_language_question': false,
    }));
    expect(plan.decision.language, 'pt');
    expect(plan.decision.source, NarrationDecisionSource.profile);
    expect(plan.decision.declaredConflict, 'en', reason: 'reported, never an alert');
    expect(plan.main?.source, 'book_voice');
    expect(plan.main?.selection?.modelId, 'pt_BR-cadu-medium');
    expect(plan.languageVoices['fr']?.modelId, 'fr_FR-siwis-medium');
    expect(plan.mainMissing, isFalse);
    expect(plan.notifyMissing.single.language, 'la');
    expect(plan.notifyMissing.single.role, NarrationLanguageRole.significant);
    expect(plan.needsLanguageQuestion, isFalse);
  });

  test('an undetermined language asks the question with the declared tag preselected', () {
    final plan = NarrationPlan.parse(jsonEncode({
      'schema_version': 1,
      'decision': {'language': null, 'source': 'undetermined', 'preselect': 'es', 'declared_conflict': null},
      'language_voices': {},
      'main_missing': false,
      'notify_missing': [],
      'needs_language_question': true,
    }));
    expect(plan.needsLanguageQuestion, isTrue);
    expect(plan.decision.preselect, 'es');
    expect(plan.main, isNull);
  });

  test('a missing main voice is flagged before any audio, and unknown values do not break the decode', () {
    final plan = NarrationPlan.parse(jsonEncode({
      'schema_version': 1,
      'decision': {'language': 'en', 'source': 'a_future_source', 'preselect': null, 'declared_conflict': null},
      'main': {'schema_version': 1, 'book_language': 'en', 'status': 'missing_model', 'reasons': [],
        'missing': {'language': 'en', 'suggested': [{'model_id': 'en_US-lessac-medium', 'engine': 'piper', 'download_bytes': 63000000}]}},
      'language_voices': {},
      'main_missing': true,
      'notify_missing': [{'language': 'x', 'role': 'a_future_role'}],
      'needs_language_question': false,
    }));
    expect(plan.mainMissing, isTrue);
    expect(plan.main?.status, LanguageModelStatus.missingModel);
    expect(plan.main?.missing?.suggested.single.modelId, 'en_US-lessac-medium');
    expect(plan.decision.source, NarrationDecisionSource.unknown);
    expect(plan.notifyMissing.single.role, NarrationLanguageRole.unknown);
  });

  test('the analysis keeps the whole Rust JSON through the cache round trip', () {
    final analysis = BookLanguageAnalysis.fromJson(Map<String, dynamic>.from(_analysis));
    final again = BookLanguageAnalysis.fromJson(Map<String, dynamic>.from(jsonDecode(jsonEncode(analysis.toJson())) as Map));
    expect(again.rawJson['profile']['languages'][1]['longest_section_chars'], 1600);
    expect(again.confirmed, 'pt');
  });
}
