import Foundation

/// Confirmation text shared by the extension UI and native localization tests.
enum ShareImportPresentation {
    static func summary(imported: Int, firstError: String?, bundle: Bundle? = nil) -> String {
        if imported > 0 {
            let key = imported == 1 ? "share.importedOne" : "share.importedMany"
            return L10n.string(key, imported, bundle: bundle)
        }
        if let firstError {
            return L10n.string("share.importFailed", firstError, bundle: bundle)
        }
        return L10n.string("share.nothingToImport", bundle: bundle)
    }
}
