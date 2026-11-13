import Foundation

@MainActor
enum BookLanguageRecovery {
    /// Consume a known language failure even when the user cancels its recovery.
    static func handle(_ error: Error, bookID: String, options: ConversionOptions,
                       isCurrent: @escaping () -> Bool,
                       retry: (ConversionOptions) -> Void) async -> Bool {
        if BookLanguageUncertain.decode(error) != nil {
            let recovered = await BookLanguagePicker.recover(error, bookID: bookID, isCurrent: isCurrent)
            if recovered, !Task.isCancelled, isCurrent() { retry(options) }
            return true
        }
        guard TtsLanguageMismatch.decode(error) != nil else { return false }
        if let choice = await TtsRecoveryAlert.choose(for: error, isCurrent: isCurrent),
           !Task.isCancelled, isCurrent() {
            retry(options.recovering(with: choice.candidate, language: choice.language))
        }
        return true
    }
}
