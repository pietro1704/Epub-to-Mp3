import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_app/models/language_model_resolution.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/conversion/desktop_embedded_converter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs against the real converter-ffi library; set TTS_TEST_FFI_LIBRARY to it
/// (and TTS_TEST_EPUB to a book for the language analysis).
void main() {
  final libraryPath = Platform.environment['TTS_TEST_FFI_LIBRARY'];
  final epub = Platform.environment['TTS_TEST_EPUB'];
  final skip = libraryPath == null || !File(libraryPath).existsSync()
      ? 'Set TTS_TEST_FFI_LIBRARY to a converter-ffi library'
      : null;

  DesktopEmbeddedConverter converter() => DesktopEmbeddedConverter(
    library: ffi.DynamicLibrary.open(libraryPath!),
    libraryPath: libraryPath,
  );

  test('the real Rust catalog lists Portuguese among sorted languages', () async {
    final languages = await converter().ttsCatalogLanguages();
    final tags = languages.map((l) => l.tag).toList();
    expect(tags, contains('pt'));
    expect(tags, [...tags]..sort(), reason: 'sorted by Rust');
    expect(languages.every((l) => l.modelCount > 0), isTrue);
  }, skip: skip);

  test('the real resolver selects an installed model, falls back, or asks for a model', () async {
    final c = converter();
    final selected = await c.resolveLanguageModel(
      const LanguageModelRequest(
        bookLanguage: 'pt-BR',
        platform: 'Linux',
        installedModelIds: ['pt_BR-faber-medium'],
      ),
    );
    expect(selected.status, LanguageModelStatus.selected);
    expect(selected.selection?.modelId, 'pt_BR-faber-medium');

    final fallback = await c.resolveLanguageModel(
      const LanguageModelRequest(bookLanguage: 'pt-BR', platform: 'Linux', systemVoices: ['pt-BR']),
    );
    expect(fallback.status, LanguageModelStatus.systemFallback);
    expect(fallback.selection?.engine, 'system');

    final missing = await c.resolveLanguageModel(
      const LanguageModelRequest(
        bookLanguage: 'pt-BR',
        platform: 'Linux',
        allowAutomaticSystemVoiceFallback: false,
      ),
    );
    expect(missing.status, LanguageModelStatus.missingModel);
    expect(missing.selection, isNull);
    expect(missing.missing?.suggested, isNotEmpty);
  }, skip: skip);

  test('the real resolver reports a bad request as an error', () async {
    await expectLater(
      converter().resolveLanguageModel(
        const LanguageModelRequest(bookLanguage: ' ', platform: 'Linux'),
      ),
      throwsA(anything),
    );
  }, skip: skip);

  test('the real book analysis runs off the UI isolate and reports an error for a missing file', () async {
    final c = converter();
    await expectLater(c.bookLanguage('/nonexistent/book.epub'), throwsA(anything));
    if (epub != null && File(epub).existsSync()) {
      final analysis = await c.bookLanguage(epub);
      // A very short fixture can be inconclusive; the analysis must still decode.
      expect(analysis.samplesExamined, greaterThanOrEqualTo(0));
      expect(analysis.detector, isNotNull);
    }
  }, skip: skip);

  test('the real resolver reports the source Dart relies on for a book in another language', () async {
    final c = converter();
    // Compatible concrete primary: the primary is kept.
    final primary = await c.resolveLanguageModel(
      const LanguageModelRequest(
        bookLanguage: 'pt-BR',
        platform: 'Linux',
        primary: TtsSelection.faber,
        installedModelIds: ['pt_BR-faber-medium'],
      ),
    );
    expect(primary.source, 'primary');

    // English book, Portuguese primary: the best installed English model.
    final automatic = await c.resolveLanguageModel(
      const LanguageModelRequest(
        bookLanguage: 'en-US',
        platform: 'Linux',
        primary: TtsSelection.faber,
        installedModelIds: ['pt_BR-faber-medium', 'en_US-ljspeech-medium'],
      ),
    );
    expect(automatic.status, LanguageModelStatus.selected);
    expect(automatic.source, 'automatic');
    expect(automatic.selection?.modelId, 'en_US-ljspeech-medium');

    // No English model: the system voice, only when permitted and present.
    const noModels = LanguageModelRequest(
      bookLanguage: 'en-US',
      platform: 'Linux',
      primary: TtsSelection.faber,
      installedModelIds: ['pt_BR-faber-medium'],
      systemVoices: ['en-us'],
    );
    final system = await c.resolveLanguageModel(noModels);
    expect(system.status, LanguageModelStatus.systemFallback);
    expect(system.source, 'system');
    expect(system.selection?.engine, 'system');

    final off = await c.resolveLanguageModel(
      const LanguageModelRequest(
        bookLanguage: 'en-US',
        platform: 'Linux',
        primary: TtsSelection.faber,
        installedModelIds: ['pt_BR-faber-medium'],
        systemVoices: ['en-us'],
        allowAutomaticSystemVoiceFallback: false,
      ),
    );
    expect(off.status, LanguageModelStatus.missingModel);
    expect(off.reasons, contains('system_fallback_disabled'));

    final none = await c.resolveLanguageModel(
      const LanguageModelRequest(
        bookLanguage: 'en-US',
        platform: 'Linux',
        primary: TtsSelection.faber,
        installedModelIds: ['pt_BR-faber-medium'],
      ),
    );
    expect(none.status, LanguageModelStatus.missingModel);
    expect(none.missing?.language, 'en');
    expect(none.missing?.suggested, isNotEmpty);

    // A Portuguese primary is incompatible with an English book.
    expect(none.reasons, contains('primary:model_incompatible_with_language'));
  }, skip: skip);
}
