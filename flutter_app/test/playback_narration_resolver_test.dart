import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/language_model_choices.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/missing_narration_dialog.dart';
import 'package:flutter_app/screens/models_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/playback/playback_narration_resolver.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Converter extends UnavailableEmbeddedConverter {
  _Converter({this.confirmed = 'pt-BR', this.answer, this.failAnalysis = false});
  String? confirmed;
  bool failAnalysis;
  LanguageModelResolution? answer;
  int analyses = 0;
  final requests = <LanguageModelRequest>[];

  @override
  Future<BookLanguageAnalysis> bookLanguage(String path) async {
    analyses++;
    if (failAnalysis) throw StateError('unreadable book');
    return BookLanguageAnalysis(confirmed: confirmed, languages: [?confirmed]);
  }

  @override
  Future<LanguageModelResolution> resolveLanguageModel(LanguageModelRequest request) async {
    requests.add(request);
    return answer!;
  }
}

const _faber = TtsSelection(engine: 'piper', modelId: 'pt_BR-faber-medium');
const _choices = LanguageModelChoices({'pt': _faber});
const _configured = TtsPreferences(primary: TtsSelection.automaticPiper, secondary: TtsSelection.system);

LanguageModelResolution _resolution(LanguageModelStatus status, {TtsSelection? selection, MissingLanguageModel? missing}) =>
    LanguageModelResolution(bookLanguage: 'pt-BR', status: status, selection: selection, missing: missing);

Future<(BookLanguageCache, String)> _fixture() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dir = await Directory.systemTemp.createTemp('narration-resolver-');
  addTearDown(() => dir.delete(recursive: true));
  final book = File('${dir.path}/book.epub')..writeAsBytesSync([1, 2, 3]);
  return (BookLanguageCache(prefs), book.path);
}

Future<PlaybackNarration> _resolve(
  _Converter converter,
  BookLanguageCache cache,
  String path, {
  LanguageModelChoices choices = _choices,
  TtsPreferences configured = _configured,
  Set<String> installed = const {'pt_BR-faber-medium'},
}) => resolvePlaybackNarration(
  converter: converter,
  cache: cache,
  bookId: 'book',
  bookPath: path,
  configured: configured,
  choices: choices,
  installedModelIds: () async => installed,
  platform: 'Linux',
);

void main() {
  group('regression: without a choice for the book language nothing changes', () {
    test('no choices at all: neither the book nor the resolver is touched', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter();
      final result = await _resolve(converter, cache, path, choices: LanguageModelChoices.empty);
      expect(result, isA<UnchangedNarration>());
      expect(converter.analyses, 0, reason: 'no parse cost for users who never chose a model');
      expect(converter.requests, isEmpty);
    });

    test('a choice for another language leaves the job as it was', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(confirmed: 'en');
      expect(await _resolve(converter, cache, path), isA<UnchangedNarration>());
      expect(converter.requests, isEmpty);
    });

    test('an unconfirmed language leaves the job as it was', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(confirmed: null);
      expect(await _resolve(converter, cache, path), isA<UnchangedNarration>());
      expect(converter.requests, isEmpty);
    });

    test('a failing analysis or an unknown status never blocks listening', () async {
      final (cache, path) = await _fixture();
      expect(await _resolve(_Converter(failAnalysis: true), cache, path), isA<UnchangedNarration>());
      final converter = _Converter(answer: _resolution(LanguageModelStatus.unknown));
      expect(await _resolve(converter, cache, path), isA<UnchangedNarration>());
    });

    test('a selected answer without a selection is ignored', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(answer: _resolution(LanguageModelStatus.selected));
      expect(await _resolve(converter, cache, path), isA<UnchangedNarration>());
    });
  });

  group('with a choice for the book language', () {
    test('selected becomes the job primary and keeps the rest of the preferences', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(answer: _resolution(LanguageModelStatus.selected, selection: _faber));
      final result = await _resolve(converter, cache, path) as ResolvedNarration;
      expect(result.preferences.primary.modelId, 'pt_BR-faber-medium');
      expect(result.preferences.secondary?.engine, 'system');
      expect(result.preferences.allowOnlineFallback, _configured.allowOnlineFallback);
    });

    test('system_fallback uses the system voice as the job primary', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        answer: _resolution(LanguageModelStatus.systemFallback, selection: TtsSelection.system),
      );
      final result = await _resolve(converter, cache, path) as ResolvedNarration;
      expect(result.preferences.primary.engine, 'system');
    });

    test('missing_model stops before a job and names the language', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        answer: _resolution(
          LanguageModelStatus.missingModel,
          missing: const MissingLanguageModel(
            language: 'pt',
            suggested: [SuggestedModel(modelId: 'pt_BR-faber-medium', downloadBytes: 63)],
          ),
        ),
      );
      final result = await _resolve(converter, cache, path) as MissingNarration;
      expect(result.language, 'pt');
      expect(result.suggested.single.modelId, 'pt_BR-faber-medium');
    });

    test('the request carries the contract inputs', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(answer: _resolution(LanguageModelStatus.selected, selection: _faber));
      await _resolve(
        converter,
        cache,
        path,
        configured: const TtsPreferences(primary: TtsSelection.faber, allowOnlineFallback: true),
        installed: {'pt_BR-faber-medium', 'en_US-lessac-medium'},
      );
      final request = converter.requests.single;
      expect(request.bookLanguage, 'pt-BR');
      expect(request.platform, 'Linux');
      expect(request.perLanguageChoices['pt']?.modelId, 'pt_BR-faber-medium');
      expect(request.primary?.modelId, 'pt_BR-faber-medium', reason: 'a concrete primary is passed');
      expect(request.allowOnlineFallback, isTrue);
      expect(request.allowAutomaticSystemVoiceFallback, isTrue);
      expect(request.installedModelIds, ['en_US-lessac-medium', 'pt_BR-faber-medium']);
    });

    test('the automatic Piper primary is not sent as a model id', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(answer: _resolution(LanguageModelStatus.selected, selection: _faber));
      await _resolve(converter, cache, path);
      expect(converter.requests.single.primary, isNull);
    });
  });

  group('book language cache', () {
    test('analyses a book once, across instances, until the file changes', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await Directory.systemTemp.createTemp('narration-cache-');
      addTearDown(() => dir.delete(recursive: true));
      final book = File('${dir.path}/book.epub')..writeAsBytesSync([1, 2, 3]);
      final converter = _Converter();

      var cache = BookLanguageCache(prefs);
      expect((await cache.analysis(converter: converter, bookId: 'b', path: book.path)).confirmed, 'pt-BR');
      await cache.analysis(converter: converter, bookId: 'b', path: book.path);
      expect(converter.analyses, 1);

      cache = BookLanguageCache(prefs); // relaunch
      await cache.analysis(converter: converter, bookId: 'b', path: book.path);
      expect(converter.analyses, 1, reason: 'restored from preferences');

      book.writeAsBytesSync([1, 2, 3, 4, 5]);
      converter.confirmed = 'en';
      expect((await cache.analysis(converter: converter, bookId: 'b', path: book.path)).confirmed, 'en');
      expect(converter.analyses, 2, reason: 'a changed file is analysed again');
    });
  });

  testWidgets('the missing-model alert opens the Models screen at that language and downloads nothing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final converter = _ModelsFixtureConverter();
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
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMissingNarrationDialog(context, language: 'pt'),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('missing-narration-dialog')), findsOneWidget);
    expect(find.text('No narration model for Português'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('missing-narration-open-models')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ModelsScreen), findsOneWidget);
    // The language section starts expanded: its Automatic row is on screen.
    expect(find.byKey(const ValueKey('model-pt-automatic')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-en-automatic')), findsNothing);
    expect(converter.installs, 0, reason: 'opening Models never downloads');
  });
}

class _ModelsFixtureConverter extends UnavailableEmbeddedConverter {
  int installs = 0;

  @override
  Future<List<TtsCatalogLanguage>> ttsCatalogLanguages() async => const [
    TtsCatalogLanguage(tag: 'en', modelCount: 1),
    TtsCatalogLanguage(tag: 'pt', modelCount: 1),
  ];

  @override
  Future<String> ttsModels() async =>
      '{"schema_version":3,"providers":[],"entries":[]}';

  @override
  Future<String?> ttsModelMetadata({required String modelId, required String root}) async => null;

  @override
  Future<String> installTtsModelFromCatalog({required String modelId, required String root}) async {
    installs++;
    return '';
  }
}
