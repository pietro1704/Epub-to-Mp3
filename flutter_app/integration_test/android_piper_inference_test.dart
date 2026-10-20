import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/main.dart' as app;
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _modelId = 'pt_BR-faber-medium';
const _modelSha256 =
    '858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7';
const _configSha256 =
    '7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f';
const _fixtureDirectory = String.fromEnvironment('FABER_FIXTURE_DIRECTORY');
const _identityOnly = bool.fromEnvironment('ANDROID_JOB_IDENTITY_ONLY');

Future<void> _expectMp3(String path) async {
  final audio = await File(path).readAsBytes();
  expect(audio.length, greaterThan(1024));
  final hasId3 = audio[0] == 0x49 && audio[1] == 0x44 && audio[2] == 0x33;
  final hasMpegSync = audio[0] == 0xff && (audio[1] & 0xe0) == 0xe0;
  expect(hasId3 || hasMpegSync, isTrue);
}

Uint8List _oneChapterEpub() {
  final mimetype = ArchiveFile.string('mimetype', 'application/epub+zip')
    ..compression = CompressionType.none;
  final archive = Archive()
    ..addFile(mimetype)
    ..addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
            '<rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>'
            '</rootfiles></container>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/package.opf',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<metadata><dc:identifier id="uid">android-faber-fixture</dc:identifier>'
            '<dc:title>Android Faber fixture</dc:title><dc:language>pt-BR</dc:language></metadata>'
            '<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>'
            '<spine><itemref idref="chapter"/></spine></package>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OPS/chapter.xhtml',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Capítulo um</title></head>'
            '<body><h1>Capítulo um</h1><p>Este é um teste real de síntese em português brasileiro. '
            'A voz Faber deve produzir áudio local sem depender de uma conexão com serviços de voz.</p></body></html>',
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<void> _verifyDefaultJobIdentity(
  AndroidEmbeddedConverter converter,
  File input,
  Directory output,
) async {
  final source = await input.readAsBytes();
  final jobs = Directory('${output.path}/.jobs');
  Future<List<File>> records() => jobs
      .list(followLinks: false)
      .where((entry) => entry is File && entry.path.endsWith('.json'))
      .cast<File>()
      .toList();
  Future<void> rejectEmptyRange() => expectLater(
    converter.convert(
      inputPath: input.path,
      outputPath: output.path,
      chapterStart: 2147483647,
      chapterEnd: 2147483647,
      optionsJson: '{"engine":"system"}',
    ),
    throwsA(
      isA<EmbeddedConversionFailure>().having(
        (error) => error.message,
        'message',
        contains('selected chapters have no readable text'),
      ),
    ),
  );

  await rejectEmptyRange();
  final firstRecords = await records();
  expect(firstRecords, hasLength(1));
  final firstRecord = firstRecords.single;
  final firstBytes = await firstRecord.readAsBytes();
  final first = jsonDecode(utf8.decode(firstBytes)) as Map<String, dynamic>;
  expect(first['state'], 'failed');
  expect((first['metadata'] as Map)['engine'], 'system');

  await rejectEmptyRange();
  final completedRecords = await records();
  expect(completedRecords, hasLength(2));
  final ids = <String>{};
  for (final file in completedRecords) {
    final record = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final id = record['job_id'] as String;
    expect(id, matches(RegExp(r'^embedded-[A-Za-z0-9_-]+$')));
    expect(ids.add(id), isTrue);
    expect(file.path, '${jobs.path}/$id.json');
    expect(record['state'], 'failed');
    expect((record['metadata'] as Map)['engine'], 'system');
    expect(await Directory('${output.path}/$id').exists(), isTrue);
  }
  expect(await firstRecord.readAsBytes(), orderedEquals(firstBytes));
  expect(await input.readAsBytes(), orderedEquals(source));
  final audio = await output
      .list(recursive: true, followLinks: false)
      .where((entry) => entry is File && entry.path.toLowerCase().endsWith('.mp3'))
      .toList();
  expect(audio, isEmpty);
  // ignore: avoid_print
  print('ANDROID_JNI_JOB_IDENTITY: defaults=2 distinct=true state=failed audio=none');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    _identityOnly
        ? 'Android JNI keeps default job identities distinct without synthesis'
        : 'Android JNI keeps job identities distinct and runs ARM64 Faber offline',
    (tester) async {
      await app.main();
      await tester.pump();

      final support = await getApplicationSupportDirectory();
      final sandbox = Directory(
        '${support.path}/android-faber-${DateTime.now().microsecondsSinceEpoch}',
      );
      final input = File('${sandbox.path}/one-chapter.epub');
      final modelsRoot = Directory('${sandbox.path}/tts-models');
      final missingModelsRoot = Directory('${sandbox.path}/empty-models');
      final output = Directory('${sandbox.path}/converted');
      final missingOutput = Directory('${sandbox.path}/missing-model-output');
      try {
        await modelsRoot.create(recursive: true);
        await missingModelsRoot.create(recursive: true);
        await input.parent.create(recursive: true);
        await input.writeAsBytes(_oneChapterEpub());

        final converter = AndroidEmbeddedConverter();
        final status = await converter.runtimeStatus();
        expect(status['runtimeLoaded'], isTrue);
        expect(status['abiCompatible'], isTrue);
        expect(status['engineReady'], isTrue);

        await _verifyDefaultJobIdentity(
          converter,
          input,
          Directory('${sandbox.path}/identity-output'),
        );
        if (_identityOnly) return;

        final catalog = (jsonDecode(await converter.ttsModels()) as List)
            .whereType<Map>()
            .map((model) => model['id'])
            .toList();
        expect(catalog, contains(_modelId));

        if (_fixtureDirectory.isNotEmpty) {
          // An explicit device-private fixture avoids any model download.
          final installed = Directory('${modelsRoot.path}/$_modelId');
          await installed.create(recursive: true);
          for (final artifact in {
            'model.onnx': _modelSha256,
            'model.onnx.json': _configSha256,
          }.entries) {
            final bytes = await File(
              '$_fixtureDirectory/${artifact.key}',
            ).readAsBytes();
            expect(sha256.convert(bytes).toString(), artifact.value);
            await File('${installed.path}/${artifact.key}').writeAsBytes(bytes);
          }
        } else {
          final installResult = await converter.installTtsModelFromCatalog(
            modelId: _modelId,
            root: modelsRoot.path,
          );
          expect(installResult, isNotEmpty);
          final metadataRaw = await converter.ttsModelMetadata(
            modelId: _modelId,
            root: modelsRoot.path,
          );
          expect(metadataRaw, isNotNull);
          final metadata = jsonDecode(metadataRaw!) as Map<String, dynamic>;
          expect(metadata['id'], _modelId);
          final artifacts = (metadata['artifacts'] as List).cast<Map>();
          expect(
            artifacts.map((artifact) => artifact['sha256']),
            containsAll([_modelSha256, _configSha256]),
          );
        }

        final options = const TtsPreferences().optionsJson(
          modelsRoot: modelsRoot.path,
          language: 'pt-BR',
        );
        final converted = await converter.convertChapter(
          inputPath: input.path,
          outputPath: output.path,
          chapterIndex: 0,
          optionsJson: options,
        );
        expect(converted.usedSelections, hasLength(1));
        expect(converted.usedSelections.single.engine, 'piper');
        expect(converted.usedSelections.single.modelId, _modelId);
        expect(converted.fallbackUsed, isFalse);
        await _expectMp3(converted.path);

        await expectLater(
          converter.convertChapter(
            inputPath: input.path,
            outputPath: missingOutput.path,
            chapterIndex: 0,
            optionsJson: const TtsPreferences().optionsJson(
              modelsRoot: missingModelsRoot.path,
              language: 'pt-BR',
            ),
          ),
          throwsA(
            isA<EmbeddedConversionFailure>().having(
              (error) => error.message,
              'message',
              contains('Piper model or voice config is not installed'),
            ),
          ),
        );
        final missingAudio = Directory(missingOutput.path).existsSync()
            ? Directory(missingOutput.path)
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((file) => file.path.toLowerCase().endsWith('.mp3'))
            : const <File>[];
        expect(missingAudio, isEmpty);

        if (_fixtureDirectory.isNotEmpty) {
          try {
            final fallback = await converter.convertChapter(
              inputPath: input.path,
              outputPath: '${sandbox.path}/native-fallback',
              chapterIndex: 0,
              optionsJson: const TtsPreferences.appDefaults().optionsJson(
                modelsRoot: missingModelsRoot.path,
                language: 'pt-BR',
              ),
            );
            expect(fallback.fallbackUsed, isTrue);
            expect(fallback.usedSelections, isNotEmpty);
            expect(
              fallback.usedSelections.every(
                (voice) => voice.engine == 'system',
              ),
              isTrue,
            );
            await _expectMp3(fallback.path);
            // ignore: avoid_print
            print(
              'ANDROID_NATIVE_FALLBACK: language=pt-BR provider=system edge=false',
            );
          } on EmbeddedConversionFailure catch (error) {
            if (!error.message.contains(
              'No installed offline speech voice for pt-BR',
            )) {
              rethrow;
            }
            // Keep missing installed voices visible without installing anything.
            // ignore: avoid_print
            print(
              'ANDROID_NATIVE_FALLBACK_BLOCKED: no installed offline pt-BR voice',
            );
          }
        }

        // ignore: avoid_print
        print(
          '${_fixtureDirectory.isEmpty ? 'ANDROID_FABER_ABI_TRANSLATION' : 'ANDROID_FABER_DEVICE_FIXTURE'}: model=$_modelId sha256=$_modelSha256 chapter=0 fallback=false missingModel=failed',
        );
      } finally {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
        expect(await sandbox.exists(), isFalse);
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
