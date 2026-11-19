import Foundation

/// A recoverable storage failure. The caller must preserve completed and
/// downloaded artifacts, then direct the user to explicit storage management.
enum StoragePressureError: LocalizedError, Equatable {
    case insufficientSpace

    var errorDescription: String? {
        switch self {
        case .insufficientSpace:
            return L10n.string("settings.insufficientStorageMessage")
        }
    }
}
