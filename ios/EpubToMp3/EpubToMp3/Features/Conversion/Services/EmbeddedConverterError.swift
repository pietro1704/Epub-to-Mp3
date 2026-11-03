import Foundation

/// Errors exposed by the optional embedded converter seam.
enum EmbeddedConverterError: Error, LocalizedError, Equatable {
    case artifactUnavailable
    case artifactInvalid(String)
    case conversionFailed(String)
    case optionsABIUnavailable

    var diagnosticDescription: String {
        switch self {
        case .artifactUnavailable: return "Embedded converter artifact is unavailable"
        case .artifactInvalid(let reason): return "Embedded converter artifact is invalid: \(reason)"
        case .conversionFailed(let reason): return "Embedded conversion failed: \(reason)"
        case .optionsABIUnavailable:
            return "Explicit conversion options require converter_session_convert_job_options_json_v1; rebuild and embed a compatible Rust converter."
        }
    }
}

extension EmbeddedConverterError {
    var errorDescription: String? {
        switch self {
        case .artifactUnavailable: return L10n.string("error.converterUnavailable")
        case .artifactInvalid, .optionsABIUnavailable: return L10n.string("error.converterIncompatible")
        case .conversionFailed(let reason):
            if TtsLanguageMismatch.decode(self) != nil || reason.contains("Model does not support this language") {
                return L10n.string("error.modelLanguage")
            }
            if reason.contains("Language is unavailable") { return L10n.string("error.voiceLanguage") }
            if reason.contains("Unsupported TTS engine") { return L10n.string("error.unsupportedEngine") }
            if reason == L10n.string("convert.error.invalidChapterRange") { return reason }
            if reason.localizedCaseInsensitiveContains("cancelled") { return L10n.string("convert.cancelled") }
            return L10n.string("error.conversionFailed")
        }
    }
}
