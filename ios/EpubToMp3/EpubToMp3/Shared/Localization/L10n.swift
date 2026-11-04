import Foundation

/// Thin namespace for localized string helpers backed by Localizable.strings.
/// The key must match an entry in Localizable.strings for en / pt-BR / es.
enum L10n {
    private static var defaultBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    /// Resolve a localized string by key from the current target bundle, or an explicitly selected localization bundle.
    static func string(_ key: String, bundle: Bundle? = nil) -> String {
        (bundle ?? defaultBundle).localizedString(forKey: key, value: key, table: nil)
    }

    /// Localised string with a single format argument.
    static func string(_ key: String, _ arg: any CVarArg, bundle: Bundle? = nil) -> String {
        let fmt = string(key, bundle: bundle)
        return String(format: fmt, arg)
    }

    /// Localised string with two format arguments.
    static func string(_ key: String, _ arg1: any CVarArg, _ arg2: any CVarArg, bundle: Bundle? = nil) -> String {
        let fmt = string(key, bundle: bundle)
        return String(format: fmt, arg1, arg2)
    }
}
