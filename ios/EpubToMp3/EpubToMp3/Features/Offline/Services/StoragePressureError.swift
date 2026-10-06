import Foundation

/// A recoverable storage failure. The caller must preserve completed and
/// downloaded artifacts, then direct the user to explicit storage management.
enum StoragePressureError: LocalizedError, Equatable {
    case insufficientSpace

    static func isInsufficientSpace(_ error: Error) -> Bool {
        if let storageError = error as? StoragePressureError {
            return storageError == .insufficientSpace
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
            return true
        }

        let description = nsError.localizedDescription.lowercased()
        return description.contains("enospc") || description.contains("no space left")
    }

    var errorDescription: String? {
        switch self {
        case .insufficientSpace:
            return L10n.string("settings.insufficientStorageMessage")
        }
    }
}
