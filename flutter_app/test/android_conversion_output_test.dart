import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/android_conversion_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AndroidEmbeddedConverter.channelName);
  late Directory sandbox;
  late Directory requested;
  late Directory job;
  late Map<String, dynamic> manifest;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('android-output-contract-');
    requested = await Directory('${sandbox.path}/requested').create();
    job = await Directory('${requested.path}/embedded-123').create();
    manifest = {
      'jobId': 'embedded-123',
      'chapters': [
        {'filename': '0001-1.mp3', 'sourceIndex': 5},
      ],
    };
    await File('${job.path}/manifest.json').writeAsString(jsonEncode(manifest));
    await File('${job.path}/0001-1.mp3').writeAsBytes([0x49, 0x44, 0x33, 1]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'status') {
            return {
              'runtimeLoaded': true,
              'abiCompatible': true,
              'engineReady': true,
            };
          }
          if (call.method == 'convert') {
            return jsonEncode({
              'manifest': manifest,
              'audioPath': '${job.path}/0001-1.mp3',
            });
          }
          throw MissingPluginException(call.method);
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await sandbox.delete(recursive: true);
  });

  test(
    'public Android conversion resolves persisted manifest and audio by job identity',
    () async {
      final converted = await AndroidEmbeddedConverter().convert(
        inputPath: '${sandbox.path}/fixture.epub',
        outputPath: requested.path,
        chapterStart: 5,
        chapterEnd: 5,
      );
      final returned = jsonDecode(converted) as Map<String, dynamic>;
      final output = await readAndroidConversionOutput(requested, returned);
      expect(output.directory.path, await job.resolveSymbolicLinks());
      expect(output.manifest, returned);
      expect(await (await output.audioFile('0001-1.mp3')).readAsBytes(), [
        0x49,
        0x44,
        0x33,
        1,
      ]);
    },
  );

  test('job identities cannot escape the requested output', () async {
    for (final id in [
      null,
      '',
      '../outside',
      '/outside',
      'nested/job',
      r'..\outside',
    ]) {
      await expectLater(
        readAndroidConversionOutput(requested, {...manifest, 'jobId': id}),
        throwsA(isA<FormatException>()),
        reason: 'Invalid job identity: $id',
      );
    }
  });

  test(
    'an output symlink cannot redirect a job outside its private root',
    () async {
      await job.delete(recursive: true);
      final outside = await Directory('${sandbox.path}/outside').create();
      await File(
        '${outside.path}/manifest.json',
      ).writeAsString(jsonEncode(manifest));
      await Link(job.path).create(outside.path);
      await expectLater(
        readAndroidConversionOutput(requested, manifest),
        throwsStateError,
      );
    },
  );

  test('a missing job directory fails without manufacturing output', () async {
    await job.delete(recursive: true);
    await expectLater(
      readAndroidConversionOutput(requested, manifest),
      throwsA(isA<FileSystemException>()),
    );
    expect(await job.exists(), isFalse);
  });

  test('audio symlinks cannot escape the resolved job directory', () async {
    final outside = await File(
      '${sandbox.path}/outside.mp3',
    ).writeAsBytes([1, 2, 3]);
    await Link('${job.path}/outside.mp3').create(outside.path);
    final output = AndroidConversionOutput(job, manifest);
    await expectLater(output.audioFile('outside.mp3'), throwsStateError);
  });

  test('conversion failure does not create a retained job', () async {
    await job.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'status') {
            return {
              'runtimeLoaded': true,
              'abiCompatible': true,
              'engineReady': true,
            };
          }
          throw PlatformException(
            code: 'CONVERSION_FAILED',
            message: 'fixture failure',
          );
        });
    await expectLater(
      AndroidEmbeddedConverter().convert(
        inputPath: '${sandbox.path}/fixture.epub',
        outputPath: requested.path,
      ),
      throwsA(isA<EmbeddedConversionFailure>()),
    );
    expect(await job.exists(), isFalse);
  });
}
