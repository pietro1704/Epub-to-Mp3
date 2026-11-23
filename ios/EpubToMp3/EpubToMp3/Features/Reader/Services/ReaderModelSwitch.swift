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
    private struct Listing { let language: String; let snapshot: SpeechModelSnapshot }
    private static var listings: [String: Listing] = [:]
    private static var cachedSystemVoiceLanguages: Set<String>?

    /// Test hook: forget everything cached for the menu.
    static func resetCachesForTesting() {
        cachedLanguages = [:]
        listings = [:]
        cachedSystemVoiceLanguages = nil
    }

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

    /// Installed system voices are scanned once, off the main thread: asking AVFoundation for them can take
    /// a noticeable time, and it used to happen on the tap that opens the menu.
    private static func systemVoices(_ scan: @escaping @Sendable () -> Set<String>) async -> Set<String> {
        if let cached = cachedSystemVoiceLanguages { return cached }
        let scanned = await Task.detached(priority: .userInitiated) { scan() }.value
        cachedSystemVoiceLanguages = scanned
        return scanned
    }

    /// `nil` when the language is unknown: the caller keeps the study-language catalog list. Once the book's
    /// models were listed, the cached listing answers at once and a refresh updates it for the next opening.
    static func content(
        picker: ReaderVoicePicker, request: ReaderVoicePickerRequest,
        source: ModelsByLanguageSource = SpeechModelsSource(),
        systemVoiceLanguages: @escaping @Sendable () -> Set<String> = ModelsByLanguageModel.installedSystemVoiceLanguages,
        languageOf: ((BookEntity) async -> String?)? = nil
    ) async -> Content? {
        guard let book = request.currentContext()?.book else { return nil }
        let resolved: String?
        if let languageOf { resolved = await languageOf(book) } else { resolved = await bookLanguage(of: book, library: request.library) }
        guard let tag = resolved else { return nil }
        let language = SpeechPreferences.languageKey(tag)
        let voices = await systemVoices(systemVoiceLanguages)
        let snapshot: SpeechModelSnapshot
        if let cached = listings[book.id], cached.language == language {
            snapshot = cached.snapshot
            Task { @MainActor in
                if let fresh = try? await source.snapshot(language: language) { listings[book.id] = Listing(language: language, snapshot: fresh) }
            }
        } else {
            guard let fresh = try? await source.snapshot(language: language) else { return nil }
            listings[book.id] = Listing(language: language, snapshot: fresh)
            snapshot = fresh
        }
        let state = ModelsByLanguageViewState.make(
            languages: [.init(tag: language, snapshot: snapshot)],
            choices: request.settings.languageModelChoices,
            allowOnlineFallback: request.settings.allowOnlineAudioFallback,
            systemVoiceLanguages: voices)
        return content(language: language, rows: state.sections.first?.rows ?? [], picker: picker)
    }

    /// The first outcome of `work` within `seconds`; `nil` means it is still running (it keeps going).
    static func firstResult<T: Sendable>(of work: Task<T, Never>, within seconds: Double) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Prepares the menu for the book so its first opening is instant (language, catalogue, installed voices).
    static func warm(request: ReaderVoicePickerRequest) {
        guard let picker = request.picker() else { return }
        Task { @MainActor in _ = await content(picker: picker, request: request) }
    }

    /// Pure part: ready rows of the language become the choices; the active voice
    /// stays visible (unavailable) when it is not one of them.
    static func content(language: String?, rows: [ModelsByLanguageViewState.Row], picker: ReaderVoicePicker) -> Content {
        var choices = rows.filter { $0.availability == .ready }.map {
            ReaderVoicePicker.Choice(selection: $0.selection, title: $0.title, selected: picker.marks($0.selection), available: true)
        }
        let hasNoModel = choices.isEmpty
        if !choices.contains(where: \.selected) {
            choices.insert(.init(selection: picker.selection, title: picker.resolvedTitle
                                    ?? SpeechModelPresentationStore.shared.displayName(
                                        engine: picker.selection.engine, modelID: picker.selection.modelID, voice: picker.selection.voice)
                                    ?? picker.selection.modelID ?? picker.selection.engine,
                                 selected: true, available: false), at: 0)
        }
        return Content(language: language, choices: choices, hasNoModel: hasNoModel)
    }
}
