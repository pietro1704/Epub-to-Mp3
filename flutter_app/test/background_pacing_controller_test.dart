import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_app/services/conversion/desktop_embedded_converter.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/services/playback/background_pacing_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _PacedConverter extends UnavailableEmbeddedConverter implements BackgroundPacingCapable {
  final limits = <int>[];

  @override
  Future<void> setBackgroundCpuLimit(int percent) async => limits.add(percent);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backgrounding paces synthesis at 50 and returning lifts the limit', () {
    final converter = _PacedConverter();
    final controller = BackgroundPacingController(converter: () => converter);
    addTearDown(controller.dispose);

    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(converter.limits, [50]);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(converter.limits, [50, 0]);
  });

  test('a locked screen (hidden) paces; transient inactive does not change the limit', () {
    final converter = _PacedConverter();
    final controller = BackgroundPacingController(converter: () => converter);
    addTearDown(controller.dispose);

    controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(converter.limits, isEmpty, reason: 'dialogs and the app switcher are not the background');
    controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(converter.limits, [50], reason: 'repeated background states are not re-sent');
  });

  test('disposing while backgrounded never leaves the process throttled', () {
    final converter = _PacedConverter();
    BackgroundPacingController(converter: () => converter)
      ..didChangeAppLifecycleState(AppLifecycleState.paused)
      ..dispose();
    expect(converter.limits, [50, 0]);
  });

  test('a converter without pacing is left alone', () {
    final controller = BackgroundPacingController(converter: () => const UnavailableEmbeddedConverter());
    addTearDown(controller.dispose);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
  });

  group('desktop library', () {
    final path = Platform.environment['TTS_TEST_FFI_LIBRARY'];
    final available = path != null && File(path).existsSync();
    ffi.DynamicLibrary? library;
    if (available) library = ffi.DynamicLibrary.open(path);
    final hasSymbol = library != null && library.providesSymbol('converter_background_cpu_limit_v1');

    test('the real Rust limit follows the lifecycle through the C ABI', () async {
      final lib = library!;
      final read = lib.lookupFunction<ffi.Uint32 Function(), int Function()>('converter_background_cpu_limit_v1');
      final converter = DesktopEmbeddedConverter(library: lib, libraryPath: path);
      final controller = BackgroundPacingController(converter: () => converter);
      addTearDown(controller.dispose);

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(read(), 50);
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(read(), 0);
    }, skip: hasSymbol ? null : 'needs a converter-ffi library with converter_set_background_cpu_limit_v1');
  });
}
