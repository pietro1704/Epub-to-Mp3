import '../../l10n/app_localizations.dart';
import 'book_language_uncertain.dart';

const _codeOpen = '[[error_code_v1]]';
const _codeClose = '[[/error_code_v1]]';

/// The stable failure code the shared Rust converter appends to a conversion
/// error (`<message> [[error_code_v1]]<code>[[/error_code_v1]]`), or null for
/// an older converter or a failure that did not come from the worker.
String? conversionErrorCode(Object error) {
  final text = error.toString();
  final start = text.indexOf(_codeOpen);
  if (start < 0) return null;
  final end = text.indexOf(_codeClose, start + _codeOpen.length);
  if (end < 0) return null;
  final code = text.substring(start + _codeOpen.length, end).trim();
  return code.isEmpty ? null : code;
}

/// The technical text of [error] without the machine marker.
String conversionErrorDetail(Object error) {
  final text = error.toString();
  final start = text.indexOf(_codeOpen);
  if (start < 0) return text;
  final end = text.indexOf(_codeClose, start);
  final tail = end < 0 ? '' : text.substring(end + _codeClose.length);
  return '${text.substring(0, start).trimRight()}$tail'.trim();
}

/// A localized, actionable message for a failed conversion, or null when the
/// job simply stopped (cancelled, replaced by a newer start, or moved away)
/// and nothing should be reported.
///
/// Codes the app does not know yet, and failures from an older converter,
/// keep their plain technical text so the code set can grow safely.
String? localizedConversionFailure(AppLocalizations t, Object error) {
  String prefixed(String message) => '${t.conversionFailed}: $message';
  final code = conversionErrorCode(error);
  if (code == null && isBookLanguageUncertain(error)) {
    return prefixed(t.bookLanguageUncertain);
  }
  // The refusal marker of Edge as primary without consent also works before
  // the converter appends error codes.
  if ((code == null || code == 'edge_consent_required') &&
      error.toString().contains('[[edge_consent_required_v1]]')) {
    return prefixed(t.errorEdgeConsentRequired);
  }
  switch (code) {
    case 'cancelled' || 'replaced' || 'playback_window_changed':
      return null;
    case 'book_language_uncertain':
      return prefixed(t.bookLanguageUncertain);
    case 'edge_consent_required':
      return prefixed(t.errorEdgeConsentRequired);
    case 'no_readable_text':
      return prefixed(t.errorNoReadableText);
    case 'engine_unavailable':
      return prefixed(t.errorEngineUnavailable);
    case 'model_missing':
      return prefixed(t.errorModelMissing);
    case 'language_model_unavailable':
      return prefixed(t.errorModelLanguage);
    case 'invalid_selection':
      return prefixed(t.errorUnsupportedEngine);
    case 'synthesis_timeout':
      return prefixed(t.errorSpeechTimeout);
    case 'edge_failed':
      return prefixed(t.errorNetwork);
    case 'rate_limited':
      return prefixed(t.errorRateLimited);
    case 'input_unreadable':
      return prefixed(t.errorInputUnreadable);
    case 'unsupported_input':
      return prefixed(t.errorUnsupportedInput);
    case 'invalid_audio' ||
        'synthesis_failed' ||
        'platform_speech_failed' ||
        'audio_output' ||
        'storage' ||
        'io' ||
        'job_state' ||
        'text_coverage' ||
        'conversion_control':
      return prefixed(t.errorConversionGeneric);
  }
  return prefixed(conversionErrorDetail(error));
}
