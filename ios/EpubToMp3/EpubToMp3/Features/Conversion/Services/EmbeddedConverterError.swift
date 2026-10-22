import Foundation

/// Errors exposed by the optional embedded converter seam.
enum EmbeddedConverterError: Error, LocalizedError, Equatable {
    case artifactUnavailable
    case artifactInvalid(String)
    case conversionFailed(String)
    case optionsABIUnavailable

    var errorDescription: String? {
        switch self {
        case .artifactUnavailable: return "Embedded converter artifact is unavailable"
        case .artifactInvalid(let reason): return "Embedded converter artifact is invalid: \(reason)"
        case .conversionFailed(let reason): return "Embedded conversion failed: \(reason)"
        case .optionsABIUnavailable:
            return "Explicit conversion options require converter_session_convert_job_options_json_v1; rebuild and embed a compatible Rust converter."
        }
    }
}
