import Foundation

/// Thin namespace for localized string helpers backed by Localizable.strings.
/// The key must match an entry in Localizable.strings for en / pt-BR / es.
enum L10n {
    /// Resolve a localized string by key from the app bundle.
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// Localised string with a single format argument.
    static func string(_ key: String, _ arg: any CVarArg) -> String {
        let fmt = string(key)
        return String(format: fmt, arg)
    }

    /// Localised string with two format arguments.
    static func string(_ key: String, _ arg1: any CVarArg, _ arg2: any CVarArg) -> String {
        let fmt = string(key)
        return String(format: fmt, arg1, arg2)
    }
}
