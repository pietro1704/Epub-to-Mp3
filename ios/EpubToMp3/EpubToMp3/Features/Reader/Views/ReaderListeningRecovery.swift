import Foundation

/// Keeps a language or model recovery bound to the listening request that failed.
@MainActor
final class ReaderListeningRecovery {
    private var generation = UUID()
    private var retry: ((TtsRecoveryAlert.Choice?) -> Void)?

    func begin(retry: @escaping (TtsRecoveryAlert.Choice?) -> Void) {
        generation = UUID()
        self.retry = retry
    }

    func invalidate() {
        generation = UUID()
        retry = nil
    }

    func report(_ error: Error, bookID: String?, isVisible: @escaping () -> Bool,
                currentBookID: @escaping () -> String?, present: (Error) -> Void) {
        let failedGeneration = generation
        let isCurrent = { [weak self] in
            self?.generation == failedGeneration && isVisible() && currentBookID() == bookID
        }
        if BookLanguageUncertain.decode(error) != nil, let bookID {
            Task { [weak self] in
                if await BookLanguagePicker.recover(error, bookID: bookID, isCurrent: isCurrent), isCurrent() {
                    self?.retry?(nil)
                }
            }
        } else if TtsLanguageMismatch.decode(error) != nil {
            Task { [weak self] in
                if let choice = await TtsRecoveryAlert.choose(for: error, isCurrent: isCurrent), isCurrent() {
                    self?.retry?(choice)
                }
            }
        } else {
            if isCurrent() { present(error) }
        }
    }
}
