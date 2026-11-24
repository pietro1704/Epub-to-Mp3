import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/language_model_choices.dart';
import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/screens/missing_narration_dialog.dart';
import 'package:flutter_app/screens/models_languages_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/playback/android_speech_fallback.dart';
import 'package:flutter_app/services/playback/playback_narration_resolver.dart';
import 'package:flutter_app/services/playback/system_voice_languages.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Converter extends UnavailableEmbeddedConverter {
  _Converter({
    this.confirmed = 'pt-BR',
    this.answer,
    this.failAnalysis = false,
  });
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
  Future<LanguageModelResolution> resolveLanguageModel(
    LanguageModelRequest request,
  ) async {
    requests.add(request);
    return answer!;
  }
}

const _faber = TtsSelection(engine: 'piper', modelId: 'pt_BR-faber-medium');
const _choices = LanguageModelChoices({'pt': _faber});
const _configured = TtsPreferences(
  primary: TtsSelection.automaticPiper,
  secondary: TtsSelection.system,
);

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
  LanguageModelChoices choices = LanguageModelChoices.empty,
  TtsPreferences configured = _configured,
  Set<String> installed = const {'pt_BR-faber-medium'},
  List<String> systemVoices = const [],
  bool explicitSelection = false,
}) => resolvePlaybackNarration(
  converter: converter,
  cache: cache,
  bookId: 'book',
  bookPath: path,
  configured: configured,
  choices: choices,
  installedModelIds: () async => installed,
  systemVoices: () async => systemVoices,
  platform: 'Linux',
  explicitSelection: explicitSelection,
);

LanguageModelResolution _answer(
  LanguageModelStatus status, {
  TtsSelection? selection,
  String? source,
  MissingLanguageModel? missing,
}) => LanguageModelResolution(
  bookLanguage: 'x',
  status: status,
  selection: selection,
  source: source,
  missing: missing,
);

const _lessac = TtsSelection(engine: 'piper', modelId: 'en_US-lessac-medium');
const _missing = MissingLanguageModel(
  language: 'en',
  suggested: [SuggestedModel(modelId: 'en_US-lessac-medium')],
);
const _faberPrimary = TtsPreferences(
  primary: TtsSelection.faber,
  secondary: TtsSelection.system,
  policyVersion: 2,
);

void main() {
  group('identical to today when the book language fits the primary', () {
    test('a compatible concrete primary leaves the job untouched', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        answer: _answer(
          LanguageModelStatus.selected,
          selection: TtsSelection.faber,
          source: 'primary',
        ),
      );
      expect(
        await _resolve(converter, cache, path, configured: _faberPrimary),
        isA<UnchangedNarration>(),
      );
      expect(converter.requests.single.primary?.modelId, 'pt_BR-faber-medium');
    });

    test('the automatic Piper primary keeps ranking installed models by language itself', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        answer: _answer(
          LanguageModelStatus.selected,
          selection: _faber,
          source: 'automatic',
        ),
      );
      expect(await _resolve(converter, cache, path), isA<UnchangedNarration>());
      expect(
        converter.requests.single.primary,
        isNull,
        reason: 'piper-auto is not a model id',
      );
    });

    test(
      'a system primary with a system voice for the language stays',
      () async {
        final (cache, path) = await _fixture();
        final converter = _Converter(
          answer: _answer(
            LanguageModelStatus.selected,
            selection: TtsSelection.system,
            source: 'primary',
          ),
        );
        expect(
          await _resolve(
            converter,
            cache,
            path,
            configured: const TtsPreferences(
              primary: TtsSelection.system,
              policyVersion: 2,
            ),
            systemVoices: ['pt-br'],
          ),
          isA<UnchangedNarration>(),
        );
      },
    );

    test(
      'an explicit selection for the job bypasses the resolver entirely',
      () async {
        final (cache, path) = await _fixture();
        final converter = _Converter(
          answer: _answer(LanguageModelStatus.missingModel, missing: _missing),
        );
        final result = await _resolve(
          converter,
          cache,
          path,
          explicitSelection: true,
        );
        expect(result, isA<UnchangedNarration>());
        expect(converter.analyses, 0);
        expect(converter.requests, isEmpty);
      },
    );

    test('an unconfirmed language, a failing analysis or an unknown status never block listening', () async {
      final (cache, path) = await _fixture();
      expect(
        await _resolve(_Converter(confirmed: null), cache, path),
        isA<UnchangedNarration>(),
      );
      expect(
        await _resolve(_Converter(failAnalysis: true), cache, path),
        isA<UnchangedNarration>(),
      );
      final converter = _Converter(
        answer: _answer(LanguageModelStatus.unknown),
      );
      expect(await _resolve(converter, cache, path), isA<UnchangedNarration>());
      expect(
        await _resolve(
          _Converter(answer: _answer(LanguageModelStatus.selected)),
          cache,
          path,
        ),
        isA<UnchangedNarration>(),
        reason: 'selected without a selection',
      );
    });
  });

  group('a book in another language than the primary, without a choice', () {
    test('uses the best installed local model', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        confirmed: 'en',
        answer: _answer(
          LanguageModelStatus.selected,
          selection: _lessac,
          source: 'automatic',
        ),
      );
      final result = await _resolve(
        converter,
        cache,
        path,
        configured: _faberPrimary,
        installed: {'pt_BR-faber-medium', 'en_US-lessac-medium'},
      ) as ResolvedNarration;
      expect(result.preferences.primary.modelId, 'en_US-lessac-medium');
      expect(
        result.preferences.secondary?.engine,
        'system',
        reason: 'the rest of the preferences is kept',
      );
      expect(converter.requests.single.perLanguageChoices, isEmpty);
    });

    test('then the system voice when the policy allows it and the platform has one', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        confirmed: 'en',
        answer: _answer(
          LanguageModelStatus.systemFallback,
          selection: TtsSelection.system,
          source: 'system',
        ),
      );
      final result = await _resolve(
        converter,
        cache,
        path,
        configured: _faberPrimary,
        systemVoices: ['en-us'],
      ) as ResolvedNarration;
      expect(result.preferences.primary.engine, 'system');
      final request = converter.requests.single;
      expect(request.allowAutomaticSystemVoiceFallback, isTrue);
      expect(request.systemVoices, ['en-us']);
    });

    test(
      'the system voice is not offered when the policy turns the fallback off',
      () async {
        final (cache, path) = await _fixture();
        final converter = _Converter(
          confirmed: 'en',
          answer: _answer(LanguageModelStatus.missingModel, missing: _missing),
        );
        await _resolve(
          converter,
          cache,
          path,
          configured: const TtsPreferences(
            primary: TtsSelection.faber,
            policyVersion: 1,
          ),
          systemVoices: ['en-us'],
        );
        expect(
          converter.requests.single.allowAutomaticSystemVoiceFallback,
          isFalse,
        );
      },
    );

    test(
      'then the missing-model alert, naming the language and the suggestions',
      () async {
        final (cache, path) = await _fixture();
        final converter = _Converter(
          confirmed: 'en',
          answer: _answer(LanguageModelStatus.missingModel, missing: _missing),
        );
        final result = await _resolve(
          converter,
          cache,
          path,
          configured: _faberPrimary,
        ) as MissingNarration;
        expect(result.language, 'en');
        expect(result.suggested.single.modelId, 'en_US-lessac-medium');
      },
    );

    test('a per-language choice wins and is sent to Rust', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        answer: _answer(
          LanguageModelStatus.selected,
          selection: _faber,
          source: 'per_language',
        ),
      );
      final result = await _resolve(
        converter,
        cache,
        path,
        configured: const TtsPreferences(
          primary: TtsSelection.edge,
          allowOnlineFallback: true,
          policyVersion: 2,
        ),
        choices: _choices,
      ) as ResolvedNarration;
      expect(result.preferences.primary.modelId, 'pt_BR-faber-medium');
      expect(
        converter.requests.single.perLanguageChoices['pt']?.modelId,
        'pt_BR-faber-medium',
      );
      expect(converter.requests.single.allowOnlineFallback, isTrue);
    });

    test('the request carries the installed models and the platform', () async {
      final (cache, path) = await _fixture();
      final converter = _Converter(
        answer: _answer(
          LanguageModelStatus.selected,
          selection: _faber,
          source: 'primary',
        ),
      );
      await _resolve(
        converter,
        cache,
        path,
        installed: {'pt_BR-faber-medium', 'en_US-lessac-medium'},
      );
      final request = converter.requests.single;
      expect(request.bookLanguage, 'pt-BR');
      expect(request.platform, 'Linux');
      expect(request.installedModelIds, [
        'en_US-lessac-medium',
        'pt_BR-faber-medium',
      ]);
    });
  });

  group('system voice languages', () {
    test('eSpeak NG voices: the language column, ignoring extra languages', () async {
      const output =
          'Pty Language       Age/Gender VoiceName          File                 Other Languages\n'
          ' 5  af              --/M      Afrikaans          gmw/af               \n'
          ' 5  pt-br           --/M      Portuguese_(Brazil) roa/pt-BR            (pt 5)\n'
          ' 5  en-us           --/M      English_(America)  gmw/en-US            (en 3)\n';
      expect(parseEspeakVoiceLanguages(output), ['af', 'pt-br', 'en-us']);
    });

    test('SAPI cultures and Android locales are normalised', () async {
      expect(parseSapiLanguages('pt-BR\r\nen-US\r\n\r\n'), ['pt-br', 'en-us']);
      final android = await enumerateSystemVoiceLanguages(
        isAndroid: true,
        isLinux: false,
        isWindows: false,
        androidVoices: () async => const [
          SpeechVoice(name: 'a', locale: 'pt_BR'),
          SpeechVoice(name: 'b', locale: 'pt_BR'),
        ],
      );
      expect(android, ['pt-br']);
    });

    test(
      'a missing engine or a failing command means no system voice',
      () async {
        Future<ProcessResult> failing(String exe, List<String> args) async =>
            throw const ProcessException('espeak-ng', []);
        expect(
          await enumerateSystemVoiceLanguages(
            isAndroid: false,
            isLinux: true,
            isWindows: false,
            run: failing,
          ),
          isEmpty,
        );
        Future<ProcessResult> broken(String exe, List<String> args) async =>
            ProcessResult(0, 1, '', 'boom');
        expect(
          await enumerateSystemVoiceLanguages(
            isAndroid: false,
            isLinux: true,
            isWindows: false,
            run: broken,
          ),
          isEmpty,
        );
      },
    );

    test('Linux asks eSpeak NG for its voices', () async {
      String? asked;
      final languages = await enumerateSystemVoiceLanguages(
        isAndroid: false,
        isLinux: true,
        isWindows: false,
        run: (exe, args) async {
          asked = '$exe ${args.join(' ')}';
          return ProcessResult(0, 0, 'Pty Language\n 5  pt-br --/M x y\n', '');
        },
      );
      expect(asked, 'espeak-ng --voices');
      expect(languages, ['pt-br']);
    });
  });

  group('book language cache', () {
    test(
      'analyses a book once, across instances, until the file changes',
      () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final dir = await Directory.systemTemp.createTemp('narration-cache-');
        addTearDown(() => dir.delete(recursive: true));
        final book = File('${dir.path}/book.epub')..writeAsBytesSync([1, 2, 3]);
        final converter = _Converter();

        var cache = BookLanguageCache(prefs);
        expect(
          (await cache.analysis(
            converter: converter,
            bookId: 'b',
            path: book.path,
          )).confirmed,
          'pt-BR',
        );
        await cache.analysis(
          converter: converter,
          bookId: 'b',
          path: book.path,
        );
        expect(converter.analyses, 1);

        cache = BookLanguageCache(prefs); // relaunch
        await cache.analysis(
          converter: converter,
          bookId: 'b',
          path: book.path,
        );
        expect(converter.analyses, 1, reason: 'restored from preferences');

        book.writeAsBytesSync([1, 2, 3, 4, 5]);
        converter.confirmed = 'en';
        expect(
          (await cache.analysis(
            converter: converter,
            bookId: 'b',
            path: book.path,
          )).confirmed,
          'en',
        );
        expect(
          converter.analyses,
          2,
          reason: 'a changed file is analysed again',
        );
      },
    );
  });

  testWidgets(
    'the missing-model alert opens the Models screen at that language and downloads nothing',
    (tester) async {
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
                onPressed: () =>
                    showMissingNarrationDialog(context, language: 'pt'),
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
      expect(
        find.byKey(const ValueKey('missing-narration-dialog')),
        findsOneWidget,
      );
      expect(find.text('No narration model for Português'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('missing-narration-open-models')),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // The Models screen opens the languages route on that language (the alert lands there).
      expect(find.byType(ModelsLanguagesScreen), findsOneWidget);
      // The language section starts expanded: its Automatic row is on screen.
      expect(find.byKey(const ValueKey('model-pt-automatic')), findsOneWidget);
      expect(find.byKey(const ValueKey('model-en-automatic')), findsNothing);
      expect(converter.installs, 0, reason: 'opening Models never downloads');
    },
  );
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
  Future<String?> ttsModelMetadata({
    required String modelId,
    required String root,
  }) async => null;

  @override
  Future<String> installTtsModelFromCatalog({
    required String modelId,
    required String root,
  }) async {
    installs++;
    return '';
  }
}
