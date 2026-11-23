import Foundation

/// The reader's live model switch (overflow menu and expanded player): it lists
/// only the models of the book's language that are ready to use. When none
/// qualifies the menu leads to the Models screen instead.
@MainActor
enum ReaderModelSwitch {
    struct Content {
        /// The book's base language; `nil` when it could not be determined.
        let language: String?
        let choices: [ReaderVoicePicker.Choice]
        /// No ready model exists for the language: the menu offers the Models screen.
        let hasNoModel: Bool

        /// Choosing keeps the language's persisted choice in step with the live switch.
        @MainActor
        func choose(_ choice: TtsSelection, picker: ReaderVoicePicker, settings: AppSettings) {
            guard !picker.marks(choice) else { return }
            if let language { settings.selectLanguageModel(choice, for: language) }
            picker.choose(choice)
        }
    }

    private static var cachedLanguages: [String: String] = [:]

    /// The authoritative language of the book, analyzed once per book by Rust.
    static func bookLanguage(of book: BookEntity, library: LibraryStore) async -> String? {
        if let cached = cachedLanguages[book.id] { return cached }
        guard let url = try? await library.openBookFileAsync(id: book.id) else { return nil }
        let analysis = try? await Task.detached(priority: .userInitiated) {
            try ConverterFFIAdapter().bookLanguage(at: url)
        }.value
        guard let tag = analysis?.confirmed ?? analysis?.languages.first ?? analysis?.declared else { return nil }
        cachedLanguages[book.id] = tag
        return tag
    }

    /// `nil` when the language is unknown: the caller keeps the study-language catalog list.
    static func content(
        picker: ReaderVoicePicker, request: ReaderVoicePickerRequest,
        source: ModelsByLanguageSource = SpeechModelsSource(),
        systemVoiceLanguages: @Sendable () -> Set<String> = ModelsByLanguageModel.installedSystemVoiceLanguages
    ) async -> Content? {
        guard let book = request.currentContext()?.book,
              let tag = await bookLanguage(of: book, library: request.library),
              let snapshot = try? await source.snapshot(language: SpeechPreferences.languageKey(tag)) else { return nil }
        let state = ModelsByLanguageViewState.make(
            languages: [.init(tag: SpeechPreferences.languageKey(tag), snapshot: snapshot)],
            choices: request.settings.languageModelChoices,
            allowOnlineFallback: request.settings.allowOnlineAudioFallback,
            systemVoiceLanguages: systemVoiceLanguages())
        return content(language: SpeechPreferences.languageKey(tag), rows: state.sections.first?.rows ?? [], picker: picker)
    }

    /// Pure part: ready rows of the language become the choices; the active voice
    /// stays visible (unavailable) when it is not one of them.
    static func content(language: String?, rows: [ModelsByLanguageViewState.Row], picker: ReaderVoicePicker) -> Content {
        var choices = rows.filter { $0.availability == .ready }.map {
            ReaderVoicePicker.Choice(selection: $0.selection, title: $0.title, selected: picker.marks($0.selection), available: true)
        }
        let hasNoModel = choices.isEmpty
        if !choices.contains(where: \.selected) {
            choices.insert(.init(selection: picker.selection, title: picker.resolvedTitle ?? picker.selection.modelID ?? TtsSelection.displayName(forEngine: picker.selection.engine) ?? picker.selection.engine,
                                 selected: true, available: false), at: 0)
        }
        return Content(language: language, choices: choices, hasNoModel: hasNoModel)
    }
}
