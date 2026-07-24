import Foundation

/// Thin namespace for localised string helpers. All app UI text routes through
/// `String(localized:)` (iOS 16+) with a polyfill for iOS 15. The key must
/// match an entry in `Localizable.strings` for en / pt-BR / es.
enum L10n {
    /// Resolve a localised string by key. iOS 16+ uses the native
    /// `String(localized:)` API; iOS 15 falls back to `NSLocalizedString`.
    static func string(_ key: String) -> String {
        if #available(iOS 16, macOS 13, *) {
            return String(localized: String.LocalizationValue(key))
        } else {
            return NSLocalizedString(key, comment: "")
        }
    }

    /// Localised string with a single format argument.
    static func string(_ key: String, _ arg: any CVarArg) -> String {
        let fmt = string(key)
        return unsafe String(format: fmt, arg)
    }

    /// Localised string with two format arguments.
    static func string(_ key: String, _ arg1: any CVarArg, _ arg2: any CVarArg) -> String {
        let fmt = string(key)
        return unsafe String(format: fmt, arg1, arg2)
    }
}
