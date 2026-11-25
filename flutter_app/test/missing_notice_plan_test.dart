import 'dart:io';

import 'package:flutter_app/models/language_model_choices.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/narration_plan.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/playback/playback_narration_resolver.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F1d: the languages of a book that have no voice come from Rust's narration plan
/// (`notify_missing`: significant languages only), and the notice is shown once per book.
class _Converter extends UnavailableEmbeddedConverter implements NarrationPlanCapable {
  _Converter({this.plan, this.planFails = false});
  NarrationPlan? plan;
  bool planFails;
  int resolves = 0;

  @override
  bool get supportsNarrationPlan => true;

  @override
  Future<BookLanguageAnalysis> bookLanguage(String path) async => BookLanguageAnalysis.fromJson({
    'confirmed': 'pt',
    'languages': ['fr', 'pt'],
    'profile': {
      'class': 'bilingual',
      'primary': 'pt',
      'languages': [
        {'language': 'pt', 'chars': 9000, 'fraction': 0.9, 'longest_section_chars': 9000, 'role': 'main'},
        {'language': 'fr', 'chars': 1000, 'fraction': 0.1, 'longest_section_chars': 1600, 'role': 'significant'},
      ],
      'incidental': [],
    },
  });

  @override
  Future<NarrationPlan> bookNarrationPlan(NarrationPlanRequest request) async {
    if (planFails) throw StateError('plan failed');
    return plan!;
  }

  @override
  Future<LanguageModelResolution> resolveLanguageModel(LanguageModelRequest request) async {
    resolves++;
    return const LanguageModelResolution(
      bookLanguage: 'fr',
      status: LanguageModelStatus.missingModel,
      missing: MissingLanguageModel(language: 'fr', suggested: []),
    );
  }
}

Future<(BookLanguageCache, String, SharedPreferences)> _fixture() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dir = await Directory.systemTemp.createTemp('missing-notice-');
  addTearDown(() => dir.delete(recursive: true));
  final book = File('${dir.path}/book.epub')..writeAsBytesSync([1, 2, 3]);
  return (BookLanguageCache(prefs), book.path, prefs);
}

Future<List<String>> _missing(_Converter converter, BookLanguageCache cache, String path) => missingProfileLanguages(
  converter: converter,
  cache: cache,
  bookId: 'book',
  bookPath: path,
  configured: const TtsPreferences(primary: TtsSelection.automaticPiper, secondary: TtsSelection.system),
  choices: LanguageModelChoices.empty,
  installedModelIds: () async => {'pt_BR-faber-medium'},
  systemVoices: () async => const [],
  platform: 'Linux',
);

void main() {
  test('the notices are the plan\'s: significant languages without a voice, nothing asked per language', () async {
    final (cache, path, _) = await _fixture();
    final converter = _Converter(
      plan: const NarrationPlan(
        decision: NarrationDecision(language: 'pt', source: NarrationDecisionSource.profile),
        notifyMissing: [NarrationMissingNotice(language: 'la', role: NarrationLanguageRole.significant)],
      ),
    );
    expect(await _missing(converter, cache, path), ['la']);
    expect(converter.resolves, 0, reason: 'Rust already decided; no per-language resolution');
  });

  test('a plan that fails leaves the per-language check to decide', () async {
    final (cache, path, _) = await _fixture();
    final converter = _Converter(planFails: true);
    expect(await _missing(converter, cache, path), ['fr']);
    expect(converter.resolves, 1);
  });

  test('a book is told about a missing language once', () async {
    final (_, _, prefs) = await _fixture();
    final notices = BookLanguageNotices(prefs);
    expect(await notices.unseen('book', ['fr', 'la']), ['fr', 'la']);
    expect(await notices.unseen('book', ['fr', 'la']), isEmpty, reason: 'already told');
    expect(await notices.unseen('book', ['fr', 'de']), ['de'], reason: 'a new language is new');
    expect(await notices.unseen('other', ['fr']), ['fr'], reason: 'another book is told on its own');
    expect(await BookLanguageNotices(prefs).unseen('book', ['fr']), isEmpty, reason: 'persisted');
  });
}
