import 'dart:ui';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/services/conversion/conversion_failure_message.dart';
import 'package:flutter_test/flutter_test.dart';

String _coded(String message, String code) =>
    '$message [[error_code_v1]]$code[[/error_code_v1]]';

Future<AppLocalizations> _l10n(String language) =>
    AppLocalizations.delegate.load(Locale(language));

void main() {
  group('marker parsing', () {
    test('reads the code and strips the marker from the technical text', () {
      final error = Exception(_coded('selected chapters have no readable text', 'no_readable_text'));
      expect(conversionErrorCode(error), 'no_readable_text');
      expect(conversionErrorDetail(error), 'Exception: selected chapters have no readable text');
    });

    test('an older converter has no code', () {
      expect(conversionErrorCode(Exception('boom')), isNull);
      expect(conversionErrorCode(Exception('x [[error_code_v1]][[/error_code_v1]]')), isNull);
      expect(conversionErrorCode(Exception('x [[error_code_v1]]unterminated')), isNull);
      expect(conversionErrorDetail(Exception('boom')), 'Exception: boom');
    });
  });

  group('localized failures', () {
    test('every known code has a message in English, Portuguese and Spanish', () async {
      const codes = [
        'no_readable_text', 'engine_unavailable', 'model_missing', 'language_model_unavailable',
        'invalid_selection', 'synthesis_timeout', 'edge_failed', 'rate_limited', 'input_unreadable',
        'unsupported_input', 'invalid_audio', 'synthesis_failed', 'platform_speech_failed',
        'audio_output', 'storage', 'io', 'job_state', 'text_coverage', 'conversion_control',
        'book_language_uncertain',
      ];
      for (final language in ['en', 'pt', 'es']) {
        final t = await _l10n(language);
        final seen = <String>{};
        for (final code in codes) {
          final message = localizedConversionFailure(t, Exception(_coded('technical detail', code)));
          expect(message, isNotNull, reason: '$language $code');
          expect(message, startsWith('${t.conversionFailed}: '));
          expect(message, isNot(contains('technical detail')), reason: 'the raw text is replaced');
          expect(message, isNot(contains('error_code_v1')));
          seen.add(message!);
        }
        expect(seen.length, greaterThan(8), reason: 'distinct causes read differently in $language');
      }
    });

    test('Apple wording is reused for the shared failures', () async {
      final pt = await _l10n('pt');
      expect(
        localizedConversionFailure(pt, Exception(_coded('x', 'no_readable_text'))),
        endsWith('Não foi possível extrair texto legível deste livro.'),
      );
      expect(
        localizedConversionFailure(pt, Exception(_coded('x', 'language_model_unavailable'))),
        endsWith('Este modelo não suporta o idioma deste livro. Escolha um modelo compatível.'),
      );
      final es = await _l10n('es');
      expect(
        localizedConversionFailure(es, Exception(_coded('x', 'synthesis_timeout'))),
        endsWith('La voz tardó demasiado en responder. Inténtalo de nuevo.'),
      );
    });

    test('a job that merely stopped reports nothing', () async {
      final t = await _l10n('en');
      for (final code in ['cancelled', 'replaced', 'playback_window_changed']) {
        expect(localizedConversionFailure(t, Exception(_coded('cancelled', code))), isNull, reason: code);
      }
    });

    test('unknown codes and older converters keep the technical text', () async {
      final t = await _l10n('en');
      expect(
        localizedConversionFailure(t, Exception(_coded('something new broke', 'future_code'))),
        '${t.conversionFailed}: Exception: something new broke',
      );
      expect(
        localizedConversionFailure(t, Exception('plain failure')),
        '${t.conversionFailed}: Exception: plain failure',
      );
    });

    test('the pre-code language marker still gets its actionable message', () async {
      final t = await _l10n('en');
      final legacy = Exception(
        'Passage language remains inconclusive [[book_language_uncertain_v1]]{"chapter_index":1}[[/book_language_uncertain_v1]]',
      );
      expect(localizedConversionFailure(t, legacy), '${t.conversionFailed}: ${t.bookLanguageUncertain}');
    });

    test('the dead NO_MODEL and ENGINE_UNAVAILABLE substrings no longer matter', () async {
      final t = await _l10n('en');
      expect(
        localizedConversionFailure(t, Exception('NO_MODEL ENGINE_UNAVAILABLE No TTS engine')),
        '${t.conversionFailed}: Exception: NO_MODEL ENGINE_UNAVAILABLE No TTS engine',
        reason: 'only the converter code decides, never text matching',
      );
    });
  });
}
