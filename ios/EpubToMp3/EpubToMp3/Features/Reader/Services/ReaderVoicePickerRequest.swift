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

    func picker() -> ReaderVoicePicker? {
        guard let context = currentContext() else { return nil }
        let bookID = context.book.id
        let selection = ReaderVoiceChange.selection(player: player, book: context.book,
            ownedJobID: context.jobID, requested: context.requestedVoice, configured: settings.primaryTtsSelection)
        let title = ReaderVoiceChange.activeVoiceTitle(player: player, book: context.book, ownedJobID: context.jobID)
        return ReaderVoicePicker(selection: selection, resolvedTitle: title) { choice in
            guard let current = currentContext(), current.book.id == bookID else { return }
            let target = ReaderVoiceChange.capture(player: player, book: current.book, starting: current.startingPosition,
                ownedJobID: current.jobID, pdfPosition: current.pdfPosition)
            settings.selectPrimaryNarration(choice)
            guard let target else { return }
            var options = NarrationConversionOptions.current(for: settings.ttsPreferences)
            options.forceReprocess = true
            restart(target, options)
        }
    }
}
