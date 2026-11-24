import Foundation

/// Applies the user's per-language model choice when a listening request starts.
///
/// Rust owns the decision (`converter_tts_resolve_language_model_json_v1`); this
/// type only gathers its inputs and turns the answer into the request's voices.
/// It never downloads anything: a missing model is reported so the caller can ask.
///
/// Rules (SETTINGS-MODELS-BY-LANGUAGE / PLAYBACK-USES-LANGUAGE-MODEL):
/// - an explicit per-job selection is authoritative and skips the resolver;
/// - otherwise the resolver always runs: the language's stored choice, else the saved primary when
///   it can read the book's language (pt with Faber = exactly today's result), else the best
///   installed local model of the language, else the system voice (if allowed), else a missing model;
/// - an unconfirmed language keeps the current confirmation flow;
/// - the language is analyzed off the main thread and cached per book.
@MainActor
enum LanguageModelPlayback {
    enum Outcome: Equatable {
        /// Use the saved preferences exactly as today.
        case useSettings
        /// The saved preferences with the language's resolved narration as primary.
        case use(TtsPreferences)
        /// No usable model for the book's language: ask, never download on its own.
        case missing(language: String)
    }

    struct Dependencies {
        var bookLanguage: (BookEntity) async -> String?
        var resolve: (LanguageModelResolutionRequest) throws -> LanguageModelResolution
        var installedModelIDs: () async -> [String]
        var systemVoiceLanguages: () -> [String]
        /// The languages of the book's profile (after `bookLanguage` analyzed it); empty when unknown.
        var profileLanguages: (BookEntity) async -> [String] = { _ in [] }
        /// The book's language analysis, when the caller has one (`bookLanguage` stays for callers that only know a tag).
        var bookAnalysis: (BookEntity) async -> BookLanguageAnalysis? = { _ in nil }
        /// The language the user set for the whole book (BookLanguageCorrections); wins over every analysis.
        var userLanguage: (BookEntity) -> String? = { _ in nil }

        @MainActor
        static func live(library: LibraryStore) -> Self {
            Self(
                bookLanguage: { await ReaderModelSwitch.bookLanguage(of: $0, library: library) },
                resolve: { try ConverterFFIAdapter().resolveLanguageModel($0) },
                installedModelIDs: {
                    guard let snapshot = try? await SpeechModelLibraryClient.shared.snapshot(probeRuntime: false) else { return [] }
                    return snapshot.entries.filter { $0.installation.state == .installed }.map(\.identity.modelID)
                },
                systemVoiceLanguages: { Array(ModelsByLanguageModel.installedSystemVoiceLanguages()) },
                profileLanguages: { ReaderModelSwitch.profileLanguages(of: $0) })
        }
    }

    static func outcome(
        for book: BookEntity, settings: AppSettings, hasExplicitSelection: Bool, dependencies: Dependencies
    ) async -> Outcome {
        guard !hasExplicitSelection else { return .useSettings }
        guard let language = await resolvedLanguage(of: book, dependencies) else { return .useSettings }
        var request = LanguageModelResolutionRequest(bookLanguage: language, platform: LanguageModelResolutionRequest.currentPlatform)
        request.perLanguageChoices = settings.languageModelChoices
        request.primary = settings.primaryTtsSelection
        request.allowOnlineFallback = settings.allowOnlineAudioFallback
        request.allowAutomaticSystemVoiceFallback = settings.allowAutomaticSystemVoiceFallback
        request.installedModelIDs = await dependencies.installedModelIDs()
        request.systemVoices = dependencies.systemVoiceLanguages()
        // A resolver failure falls back to today's behavior rather than blocking playback.
        guard let resolution = try? dependencies.resolve(request) else { return .useSettings }
        switch resolution.status {
        case .missingModel:
            return .missing(language: language)
        case .selected, .systemFallback:
            guard let selection = resolution.selection else { return .useSettings }
            let current = settings.ttsPreferences
            guard selection != current.primary else { return .useSettings }
            var preferences = current
            preferences.primary = selection
            // The reserve must still differ from the primary and respect the online consent.
            if let secondary = preferences.secondary,
               !secondary.canBeSecondary(to: selection, allowOnlineFallback: preferences.allowOnlineFallback) {
                preferences.secondary = nil
            }
            return .use(preferences)
        }
    }

    /// The language the model is resolved for. (First step of the fix: still the analysis tag only.)
    static func resolvedLanguage(of book: BookEntity, _ dependencies: Dependencies) async -> String? {
        await dependencies.bookLanguage(book)
    }

    /// Languages of the book's profile, other than its main one, that have no usable voice. A warning before playing,
    /// never a block: the main voice reads those passages and installing a model stays an explicit action.
    static func missingProfileLanguages(
        for book: BookEntity, settings: AppSettings, dependencies: Dependencies
    ) async -> [String] {
        guard let main = await resolvedLanguage(of: book, dependencies) else { return [] }
        let mainKey = SpeechPreferences.languageKey(main)
        var seen: Set<String> = [mainKey]
        var missing: [String] = []
        let installed = await dependencies.installedModelIDs()
        for language in await dependencies.profileLanguages(book) {
            let key = SpeechPreferences.languageKey(language)
            guard seen.insert(key).inserted else { continue }
            var request = LanguageModelResolutionRequest(bookLanguage: language, platform: LanguageModelResolutionRequest.currentPlatform)
            request.perLanguageChoices = settings.languageModelChoices
            request.primary = settings.primaryTtsSelection
            request.allowOnlineFallback = settings.allowOnlineAudioFallback
            request.allowAutomaticSystemVoiceFallback = settings.allowAutomaticSystemVoiceFallback
            request.installedModelIDs = installed
            request.systemVoices = dependencies.systemVoiceLanguages()
            // A resolver failure never blocks or warns.
            guard let resolution = try? dependencies.resolve(request), resolution.status == .missingModel else { continue }
            missing.append(key)
        }
        return missing
    }

    /// Options for a background conversion of a book (offline chapters): the language's resolved
    /// narration like a listening request, and the missing-model error the shared recovery messages
    /// understand when nothing can read the language.
    static func conversionOptions(
        for book: BookEntity, settings: AppSettings, dependencies: Dependencies
    ) async throws -> ConversionOptions {
        switch await outcome(for: book, settings: settings, hasExplicitSelection: false, dependencies: dependencies) {
        case .useSettings: return NarrationConversionOptions.current(for: settings.ttsPreferences)
        case let .use(preferences): return NarrationConversionOptions.current(for: preferences)
        case let .missing(language): throw missingModelError(language: language)
        }
    }

    /// The same mismatch the conversion reports, so the existing recovery alert (download the
    /// recommended model, use the system voice, open Models) handles it on every platform.
    static func missingModelError(language: String) -> Error {
        let context = (try? JSONSerialization.data(withJSONObject: ["language": language, "model_id": "piper"],
                                                   options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return EmbeddedConverterError.conversionFailed(
            "No installed voice for book language [[tts_language_mismatch_v1]]" + context + "[[/tts_language_mismatch_v1]]")
    }
}
