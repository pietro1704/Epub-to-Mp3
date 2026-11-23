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
            return "Explicit conversion options require converter_session_convert_streaming_job_options_json_v1; rebuild and embed a compatible Rust converter."
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
            if EdgeConsentRequired.decode(self) != nil { return L10n.string("error.edgeConsentRequired") }
            if BookLanguageUncertain.decode(self) != nil { return L10n.string("error.bookLanguageUncertain") }
            if reason.contains("Language is unavailable") { return L10n.string("error.voiceLanguage") }
            if reason.contains("Unsupported TTS engine") { return L10n.string("error.unsupportedEngine") }
            if reason == L10n.string("convert.error.invalidChapterRange") { return reason }
            if reason.localizedCaseInsensitiveContains("cancelled") { return L10n.string("convert.cancelled") }
            return L10n.string("error.conversionFailed")
        }
    }
}

/// Rust refused an online Edge voice (primary or secondary) because the online
/// consent is off. The marker is the contract; the English reason is never parsed.
struct EdgeConsentRequired: Decodable, Sendable, Equatable {
    let role: String?
    static func decode(_ error: Error) -> Self? {
        guard case .conversionFailed(let reason) = error as? EmbeddedConverterError,
              let start = reason.range(of: "[[edge_consent_required_v1]]"),
              let end = reason.range(of: "[[/edge_consent_required_v1]]", range: start.upperBound..<reason.endIndex)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(reason[start.upperBound..<end.lowerBound].utf8))
    }
}
