import Foundation

/// Shared reader command behind the native voice selectors.
@MainActor
struct ReaderVoicePickerRequest {
    struct Context {
        let book: BookEntity
        var jobID: String? = nil
        var requestedVoice: TtsSelection? = nil
        var startingPosition: ReaderVoiceChange? = nil
        var pdfPosition: (chapter: Int, offset: Int)? = nil
    }

    let settings: AppSettings
    let library: LibraryStore
    let player: AudioPlayer
    let currentContext: () -> Context?
    let restart: (ReaderVoiceChange, ConversionOptions) -> Void
    /// Resolves the language's voice when the book stops using its own; the live dependencies by default.
    var dependencies: LanguageModelPlayback.Dependencies? = nil

    func picker() -> ReaderVoicePicker? {
        guard let context = currentContext() else { return nil }
        let bookID = context.book.id
        let bookVoice = settings.bookVoices.voice(bookID: bookID)
        let selection = ReaderVoiceChange.selection(player: player, book: context.book,
            ownedJobID: context.jobID, requested: context.requestedVoice,
            configured: bookVoice ?? settings.primaryTtsSelection)
        let title = ReaderVoiceChange.activeVoiceTitle(player: player, book: context.book, ownedJobID: context.jobID)
        let capture: @MainActor (Context) -> ReaderVoiceChange? = { current in
            ReaderVoiceChange.capture(player: player, book: current.book, starting: current.startingPosition,
                ownedJobID: current.jobID, pdfPosition: current.pdfPosition)
        }
        var picker = ReaderVoicePicker(selection: selection, resolvedTitle: title) { choice in
            guard let current = currentContext(), current.book.id == bookID else { return }
            let target = capture(current)
            settings.bookVoices.set(choice, bookID: bookID)
            guard let target else { return }
            var preferences = settings.ttsPreferences
            preferences.primary = choice
            if let secondary = preferences.secondary,
               !secondary.canBeSecondary(to: choice, allowOnlineFallback: preferences.allowOnlineFallback) {
                preferences.secondary = nil
            }
            var options = NarrationConversionOptions.current(for: preferences)
            options.forceReprocess = true
            restart(target, options)
        }
        guard bookVoice != nil else { return picker }
        picker.useDefault = {
            guard let current = currentContext(), current.book.id == bookID else { return }
            let target = capture(current)
            settings.bookVoices.set(nil, bookID: bookID)
            guard let target else { return }
            let resolved = try? await LanguageModelPlayback.conversionOptions(
                for: current.book, settings: settings, dependencies: dependencies ?? .live(library: library))
            // The listener may have left the book or picked another voice while the language was resolved.
            guard currentContext()?.book.id == bookID, settings.bookVoices.voice(bookID: bookID) == nil else { return }
            var options = resolved ?? NarrationConversionOptions.current(for: settings.ttsPreferences)
            options.forceReprocess = true
            restart(target, options)
        }
        return picker
    }
}
