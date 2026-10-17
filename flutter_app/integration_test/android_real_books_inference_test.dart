import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/main.dart' as app;
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'android_piper_inference_test.dart' as smoke;

const _fixtureManifest = String.fromEnvironment('REAL_BOOK_FIXTURE_MANIFEST');
const _smokeFixtureDirectory = String.fromEnvironment(
  'FABER_FIXTURE_DIRECTORY',
);
const _modelId = 'pt_BR-faber-medium';
const _modelArtifacts = {
  'model.onnx':
      '858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7',
  'model.onnx.json':
      '7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f',
};
const _books = {
  'lotr': (
    sha256: '3e1c676b270dfa3fe555eba4d0cb993486e9f00facb7cc92eef250e64efb7c9e',
    bytes: 8489264,
    language: 'en',
    start: 8,
    end: 9,
    provider: 'system',
  ),
  'christie': (
    sha256: '55417053355de78768a0823d3cd203fde5c80bd8026407ffb5766b3f730d11da',
    bytes: 2985724,
    language: 'pt',
    start: 5,
    end: 6,
    provider: 'piper',
  ),
  'akita': (
    sha256: 'f937c4516065ae5d9f5e07c1eb41656b6eba33d0b028810822f2105ba896bc57',
    bytes: 26126975,
    language: 'pt-BR',
    start: 4,
    end: 5,
    provider: 'piper',
  ),
};

Future<void> _expectHash(File file, String expected) async {
  expect((await sha256.bind(file.openRead()).single).toString(), expected);
}

Future<String> _privatePath(String path, String root) async {
  final resolved = await File(path).resolveSymbolicLinks();
  expect(resolved.startsWith('$root/'), isTrue);
  return resolved;
}

void main() {
  if (_fixtureManifest.isEmpty || _smokeFixtureDirectory.isEmpty) {
    throw StateError('Explicit private book and Faber fixtures are required');
  }
  // The smoke initializes the integration binding and never downloads a model
  // when its explicit fixture is supplied. Run it before the longer book cases.
  smoke.main();

  for (final id in ['christie', 'akita', 'lotr']) {
    final entry = MapEntry(id, _books[id]!);
    testWidgets(
      'Android converts two narrative chapters of ${entry.key} offline',
      (tester) async {
        expect(_fixtureManifest, isNotEmpty);
        await app.main();
        await tester.pump();
        final support = await getApplicationSupportDirectory();
        final supportPath = await support.resolveSymbolicLinks();
        final fixturePath = await _privatePath(_fixtureManifest, supportPath);
        final fixture =
            jsonDecode(await File(fixturePath).readAsString()) as Map;
        final books = (fixture['books'] as List).cast<Map>();
        final book = books.singleWhere((book) => book['id'] == entry.key);
        final expected = entry.value;
        final inputPath = await _privatePath(
          book['path'] as String,
          supportPath,
        );
        final input = File(inputPath);
        expect(await input.length(), expected.bytes);
        await _expectHash(input, expected.sha256);
        expect(book['sha256'], expected.sha256);
        expect(book['language'], expected.language);
        expect(book['chapterStart'], expected.start);
        expect(book['chapterEnd'], expected.end);
        expect(book['expectedProvider'], expected.provider);
        final start = book['chapterStart'] as int;
        final end = book['chapterEnd'] as int;
        expect(end - start + 1, inInclusiveRange(1, 2));

        final modelsRoot = fixture['modelsRoot'] as String;
        for (final artifact in _modelArtifacts.entries) {
          final path = await _privatePath(
            '$modelsRoot/$_modelId/${artifact.key}',
            supportPath,
          );
          await _expectHash(File(path), artifact.value);
        }
        final converter = AndroidEmbeddedConverter();
        final status = await converter.runtimeStatus();
        expect(status['runtimeLoaded'], isTrue);
        expect(status['abiCompatible'], isTrue);
        expect(status['engineReady'], isTrue);

        // Keep the raw public metadata, including the original EPUB language.
        const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
        final raw = await channel.invokeMethod<String>('parse', {
          'inputPath': inputPath,
        });
        expect(raw, isNotNull);
        final metadata = jsonDecode(raw!) as Map;
        expect(metadata['language'], expected.language);
        expect(metadata['title'], book['title']);
        final source = (metadata['chapters'] as List).cast<Map>();
        final selected = (book['chapters'] as List).cast<Map>();
        expect(selected, hasLength(end - start + 1));
        for (var offset = 0; offset < selected.length; offset++) {
          final chapter = selected[offset];
          expect(chapter['position'], start + offset);
          for (final key in ['index', 'name', 'sourcePath']) {
            expect(source[start + offset][key], chapter[key]);
          }
        }

        final output = Directory(
          '${support.path}/real-books-${entry.key}-'
          '${DateTime.now().microsecondsSinceEpoch}',
        );
        final options = const TtsPreferences.appDefaults().optionsJson(
          modelsRoot: modelsRoot,
          language: metadata['language'] as String,
        );
        final converted = await converter.convert(
          inputPath: inputPath,
          outputPath: output.path,
          chapterStart: start,
          chapterEnd: end,
          optionsJson: options,
        );
        final manifest = jsonDecode(converted) as Map;
        final persisted = jsonDecode(
          await File('${output.path}/manifest.json').readAsString(),
        );
        expect(persisted, manifest);
        expect(manifest['title'], book['title']);
        expect(manifest['sourceChaptersTotal'], source.length);
        final preferences = manifest['ttsPreferences'] as Map;
        expect(preferences['policy_version'], 2);
        expect((preferences['primary'] as Map)['engine'], 'piper');
        expect((preferences['primary'] as Map)['model_id'], _modelId);
        expect((preferences['secondary'] as Map)['engine'], 'system');
        expect(preferences['allow_online_fallback'], isFalse);
        final voices = (manifest['usedSelections'] as List).cast<Map>();
        expect(voices, isNotEmpty);
        expect(
          voices.every((voice) => voice['engine'] == expected.provider),
          isTrue,
        );
        if (expected.provider == 'piper') {
          expect(
            voices.every((voice) => voice['model_id'] == _modelId),
            isTrue,
          );
        }
        expect(manifest['fallbackUsed'] == true, expected.provider == 'system');
        final chapters = (manifest['chapters'] as List).cast<Map>();
        expect(chapters, hasLength(selected.length));
        for (var offset = 0; offset < chapters.length; offset++) {
          final chapter = chapters[offset];
          expect(chapter['sourceIndex'], start + offset);
          expect(chapter['title'], selected[offset]['name']);
          final audioPath = await _privatePath(
            '${output.path}/${chapter['filename']}',
            await output.resolveSymbolicLinks(),
          );
          final audio = File(audioPath);
          expect(await audio.length(), greaterThan(1024));
          final stream = await audio.open();
          try {
            final header = await stream.read(3);
            final id3 =
                header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33;
            final mpeg = header[0] == 0xff && (header[1] & 0xe0) == 0xe0;
            expect(id3 || mpeg, isTrue);
          } finally {
            await stream.close();
          }
        }
        // Retain only this test's artifacts for host-side ffprobe/decode checks.
        await File('${output.path}/verification.json').writeAsString(
          jsonEncode({
            'bookId': entry.key,
            'inputSha256': expected.sha256,
            'language': metadata['language'],
            'chapterStart': start,
            'chapterEnd': end,
            'expectedProvider': expected.provider,
            'manifest': manifest,
          }),
        );
        // ignore: avoid_print
        print('ANDROID_REAL_BOOK_VERIFIED: ${entry.key} output=${output.path}');
      },
      timeout: const Timeout(Duration(hours: 2)),
    );
  }
}
