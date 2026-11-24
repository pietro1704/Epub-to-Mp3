import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/language_model_choices.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/missing_narration_dialog.dart';
import 'package:flutter_app/screens/models_language_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/playback/playback_narration_resolver.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The profile JSON Rust adds to the book language analysis (BOOK-LANGUAGE-PROFILE).
Map<String, dynamic> _analysis(
  String classification,
  List<(String, double)> languages, {
  List<String> incidental = const [],
}) => {
  'declared': 'pt-BR',
  'confirmed': 'pt-BR',
  'languages': [for (final (tag, _) in languages) tag],
  'samples_examined': 5,
  'inconclusive_samples': 0,
  'detector': 'x',
  'profile': {
    'version': 1,
    'class': classification,
    'primary': languages.first.$1,
    'languages': [
      for (final (tag, fraction) in languages)
        {
          'language': tag,
          'chars': (fraction * 1000).round(),
          'fraction': fraction,
          'longest_section_chars': 2000,
        },
    ],
    'incidental': incidental,
    'total_chars': 1000,
    'undetermined_chars': 0,
  },
};

class _Converter extends UnavailableEmbeddedConverter {
  _Converter(this.analysis, {this.missing = const {}});
  final Map<String, dynamic> analysis;
  final Set<String> missing; // base languages with no usable model
  final requests = <String>[];

  @override
  Future<BookLanguageAnalysis> bookLanguage(String path) async =>
      BookLanguageAnalysis.fromJson(analysis);

  @override
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages() async => const [
    TtsCatalogLanguage(tag: 'en', modelCount: 1),
    TtsCatalogLanguage(tag: 'fr', modelCount: 1),
    TtsCatalogLanguage(tag: 'pt', modelCount: 1),
  ];

  @override
  Future<String> ttsModels() async =>
      '{"schema_version":3,"providers":[],"entries":[]}';

  @override
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => null;

  @override
  Future<LanguageModelResolution> resolveLanguageModel(
    LanguageModelRequest request,
  ) async {
    requests.add(request.bookLanguage);
    final base = LanguageModelChoices.baseLanguage(request.bookLanguage);
    return LanguageModelResolution(
      bookLanguage: request.bookLanguage,
      status: missing.contains(base)
          ? LanguageModelStatus.missingModel
          : LanguageModelStatus.selected,
      selection: missing.contains(base)
          ? null
          : const TtsSelection(engine: 'piper', modelId: 'm'),
      source: 'automatic',
      missing: missing.contains(base)
          ? MissingLanguageModel(language: base, suggested: const [])
          : null,
    );
  }
}

Future<(BookLanguageCache, String)> _fixture() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dir = await Directory.systemTemp.createTemp('profile-notice-');
  addTearDown(() => dir.delete(recursive: true));
  final book = File('${dir.path}/book.epub')..writeAsBytesSync([1, 2, 3]);
  return (BookLanguageCache(prefs), book.path);
}

Future<List<String>> _missing(
  _Converter converter,
  BookLanguageCache cache,
  String path, [
  String bookId = 'book',
]) => missingProfileLanguages(
  converter: converter,
  cache: cache,
  bookId: bookId,
  bookPath: path,
  configured: const TtsPreferences(
    primary: TtsSelection.automaticPiper,
    secondary: TtsSelection.system,
  ),
  choices: LanguageModelChoices.empty,
  installedModelIds: () async => {'pt_BR-faber-medium'},
  systemVoices: () async => const [],
  platform: 'Linux',
);

void main() {
  test('the analysis carries the whole-book profile (additive: older Rust has none)', () {
    final profile = BookLanguageAnalysis.fromJson(
      _analysis(
        'bilingual',
        [('pt-BR', .6), ('en-US', .4)],
        incidental: ['fr-FR'],
      ),
    ).profile!;
    expect(profile.classification, BookLanguageClass.bilingual);
    expect(profile.primary, 'pt-BR');
    expect(
      [for (final share in profile.languages) share.language],
      ['pt-BR', 'en-US'],
    );
    expect(profile.languages[1].fraction, closeTo(.4, 1e-9));
    expect(profile.incidental, ['fr-FR']);
    expect(
      BookLanguageAnalysis.fromJson({
        'languages': ['pt-BR'],
      }).profile,
      isNull,
    );
    // The cached copy keeps the profile.
    final again = BookLanguageAnalysis.fromJson(
      BookLanguageAnalysis.fromJson(_analysis('monolingual', [('pt-BR', 1.0)]))
          .toJson(),
    );
    expect(again.profile?.classification, BookLanguageClass.monolingual);
  });

  test('a bilingual book warns, before playing, about the languages that have no model', () async {
    final (cache, path) = await _fixture();
    final converter = _Converter(
      _analysis('bilingual', [('pt-BR', .6), ('en-US', .4)]),
      missing: {'en'},
    );
    expect(await _missing(converter, cache, path), ['en']);
    // Only the book's other languages are resolved: the main voice's language is the job's own.
    expect(converter.requests, ['en-US']);
  });

  test('nothing is said when the other language already has a model, or for a monolingual book', () async {
    final (cache, path) = await _fixture();
    expect(
      await _missing(
        _Converter(_analysis('bilingual', [('pt-BR', .6), ('en-US', .4)])),
        cache,
        path,
        'has-model',
      ),
      isEmpty,
    );
    final monolingual = _Converter(
      _analysis('monolingual', [('pt-BR', .97)], incidental: ['fr-FR']),
      missing: {'fr', 'en'},
    );
    expect(
      await _missing(monolingual, cache, path, 'quotes'),
      isEmpty,
      reason: 'quotations never ask for a model',
    );
    expect(monolingual.requests, isEmpty);
  });

  test(
    'a multilingual book lists every missing language once, in share order',
    () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        _analysis('multilingual', [
          ('pt-BR', .5),
          ('en-US', .3),
          ('fr-FR', .2),
        ]),
        missing: {'fr', 'en'},
      );
      expect(await _missing(converter, cache, path, 'multi'), ['en', 'fr']);
    },
  );

  testWidgets(
    'the notice is a snackbar that never blocks and leads to the Models languages',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final converter = _Converter(
        _analysis('bilingual', [('pt-BR', .6), ('en-US', .4)]),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            embeddedConverterProvider.overrideWithValue(converter),
            ttsModelRootProvider.overrideWith((_) => '/fixture-models'),
            systemVoiceLanguagesProvider.overrideWith((_) async => const <String>[]),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showMissingProfileModelsNotice(
                    context,
                    const ['en', 'fr'],
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('missing-profile-models-notice')),
        findsOneWidget,
      );
      expect(find.textContaining('English'), findsOneWidget);
      expect(find.textContaining('Français'), findsOneWidget);
      await tester.tap(find.text('Open Models'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ModelsLanguageScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('model-en-automatic')),
        findsOneWidget,
        reason: 'opens on the first missing language',
      );
    },
  );
}
