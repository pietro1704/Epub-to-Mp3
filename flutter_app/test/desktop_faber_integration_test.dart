import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/desktop_embedded_converter.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _OrtGetApiNative = ffi.Pointer<ffi.Void> Function(ffi.Uint32);
typedef _OrtVersionNative = ffi.Pointer<Utf8> Function();

// Published OrtApiBase layout; Windows x64 uses the unified system C ABI.
final class _OrtApiBase extends ffi.Struct {
  external ffi.Pointer<ffi.NativeFunction<_OrtGetApiNative>> getApi;
  external ffi.Pointer<ffi.NativeFunction<_OrtVersionNative>> getVersionString;
}

String _preloadPackagedWindowsOrt(String library) {
  // flutter_tester runs outside Release/. Replicate the shipped executable's
  // adjacent dependency context without changing the product adapter or PATH.
  final path = '${File(library).parent.path}/onnxruntime.dll';
  expect(File(path).existsSync(), true);
  final runtime = ffi.DynamicLibrary.open(path);
  final base = runtime.lookupFunction<ffi.Pointer<_OrtApiBase> Function(),
      ffi.Pointer<_OrtApiBase> Function()>('OrtGetApiBase')();
  expect(base, isNot(ffi.nullptr));
  final version = base.ref.getVersionString
      .asFunction<ffi.Pointer<Utf8> Function()>()()
      .toDartString();
  expect(version, '1.24.4');
  expect(base.ref.getApi.asFunction<ffi.Pointer<ffi.Void> Function(int)>()(23),
      isNot(ffi.nullptr));
  return version;
}

String _requiredPath(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty || !File(value).isAbsolute) {
    throw StateError('$name must name an explicit absolute test path');
  }
  return value;
}

void main() {
  final enabled = Platform.environment['EPUB_DART_FABER_INTEGRATION'] == '1';
  test(
    'real Dart desktop adapter converts exactly two public chapters with Faber',
    () async {
      expect(Platform.isLinux || Platform.isWindows, true);
      final library = _requiredPath('EPUB_DART_FABER_LIBRARY');
      final models = _requiredPath('EPUB_DART_FABER_MODELS');
      final report = _requiredPath('EPUB_DART_FABER_REPORT');
      final ortVersion = Platform.isWindows ? _preloadPackagedWindowsOrt(library) : null;
      final input = File('../web/public/sample.epub').absolute;
      expect(await input.exists(), true);
      final directory = await Directory.systemTemp.createTemp('dart-faber-owned-');
      const jobId = 'dart-faber %20#identity';
      final output = '${directory.path}/$jobId';
      try {
        final converter = DesktopEmbeddedConverter(libraryPath: library);
        final elapsed = Stopwatch()..start();
        final raw = await converter.convert(
          inputPath: input.path,
          outputPath: '$output/',
          chapterStart: 0,
          chapterEnd: 1,
          optionsJson: const TtsPreferences().optionsJson(
            modelsRoot: models,
            language: 'pt-BR',
          ),
        );
        elapsed.stop();
        // convert() intentionally unwraps the FFI envelope at the public seam.
        final manifest = jsonDecode(raw) as Map<String, dynamic>;
        expect(manifest['jobId'], jobId);
        // Rust omits false fallbackUsed; absence means false, not missing evidence.
        expect(manifest['fallbackUsed'] ?? false, false);
        expect(manifest['sourceChaptersTotal'], 2);
        final selections = (manifest['usedSelections'] as List).cast<Map>();
        expect(selections, hasLength(1));
        expect(selections.single['engine'], 'piper');
        expect(selections.single['model_id'], 'pt_BR-faber-medium');
        final chapters = (manifest['chapters'] as List).cast<Map>();
        expect(chapters, hasLength(2));
        expect(chapters.map((chapter) => chapter['sourceIndex']), [0, 1]);
        final persisted = jsonDecode(await File('$output/manifest.json').readAsString());
        expect(persisted, manifest);
        final audio = <Map<String, Object>>[];
        for (final chapter in chapters) {
          final filename = chapter['filename'] as String;
          expect(filename.contains('/'), false);
          expect(filename.contains(String.fromCharCode(92)), false);
          final path = '$output/$filename';
          final decoded = await Process.run(
            'ffmpeg',
            ['-nostdin', '-v', 'error', '-xerror', '-i', path, '-ac', '1', '-ar', '16000', '-f', 'f32le', 'pipe:1'],
            stdoutEncoding: null,
          );
          expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
          final bytes = Uint8List.fromList(decoded.stdout as List<int>);
          expect(bytes.length, greaterThan(0));
          expect(bytes.length % 4, 0);
          final samples = ByteData.sublistView(bytes);
          var peak = 0.0;
          for (var offset = 0; offset < bytes.length; offset += 4) {
            peak = max(peak, samples.getFloat32(offset, Endian.little).abs());
          }
          expect(peak.isFinite, true);
          expect(peak, greaterThan(0.001));
          audio.add({'sourceIndex': chapter['sourceIndex'] as int, 'decodedSamples': bytes.length ~/ 4, 'peak': peak});
        }
        await File(report).parent.create(recursive: true);
        await File(report).writeAsString(jsonEncode({
          'jobId': jobId, 'input': 'web/public/sample.epub',
          'chapterStart': 0, 'chapterEnd': 1,
          'modelId': 'pt_BR-faber-medium', 'fallbackUsed': false,
          if (ortVersion != null) 'ortVersion': ortVersion,
          'elapsedMs': elapsed.elapsedMilliseconds,
          'timingScope': Platform.isWindows
              ? 'GitHub-hosted Windows full conversion; no phone or first-playable latency claim'
              : 'GitHub-hosted Linux full conversion; no phone or first-playable latency claim',
          'outputs': audio,
        }));
        stdout.writeln('DART_FABER_NATIVE: model=pt_BR-faber-medium chapters=2');
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: enabled ? false : 'Explicit GitHub real-runtime opt-in required',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
