import Foundation

/// Swift projection of `converter_book_narration_plan_json_v1` (A1). Rust owns every decision; these types only
/// carry its inputs and its answer.
struct NarrationPlanInputs: Sendable, Equatable {
    /// The voice settings and what is installed, exactly as a resolution request carries them (its `bookLanguage`
    /// is ignored: the plan decides the language).
    var voices: LanguageModelResolutionRequest
    var userCorrection: String? = nil
    /// The listener's own voice for this one book.
    var bookVoice: TtsSelection? = nil

    /// The request body. `bookLanguageJSON` is the untouched answer of `converter_book_language_json_v1`: its
    /// `profile` and analysis are forwarded as Rust wrote them, so no field is lost in a Swift round trip.
    func requestBody(bookLanguageJSON: Data) throws -> Data {
        throw EmbeddedConverterError.artifactUnavailable
    }
}

struct NarrationPlan: Decodable, Sendable, Equatable {
    struct Decision: Decodable, Sendable, Equatable {
        let language: String?
        /// `user_correction`, `profile`, `confirmed` or `undetermined`; kept as text so a newer Rust never fails the plan.
        let source: String
        let preselect: String?
        let declaredConflict: String?
        enum CodingKeys: String, CodingKey {
            case language, source, preselect
            case declaredConflict = "declared_conflict"
        }
    }

    struct MissingNotice: Decodable, Sendable, Equatable {
        let language: String
        let role: String
    }

    let decision: Decision
    let main: LanguageModelResolution?
    let languageVoices: [String: TtsSelection]
    let mainMissing: Bool
    let notifyMissing: [MissingNotice]
    let needsLanguageQuestion: Bool

    enum CodingKeys: String, CodingKey {
        case decision, main
        case languageVoices = "language_voices"
        case mainMissing = "main_missing"
        case notifyMissing = "notify_missing"
        case needsLanguageQuestion = "needs_language_question"
    }
}
