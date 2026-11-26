import Foundation

/// Thin namespace for localized string helpers backed by Localizable.strings.
/// The key must match an entry in Localizable.strings for en / pt-BR / es.
enum L10n {
    /// Test seam: forces every lookup that does not pass its own bundle into one localization.
    nonisolated(unsafe) static var bundleOverrideForTesting: Bundle?

    /// The bundle of one shipped localization ("en", "pt-BR", "es"), for tests and explicit-language lookups.
    static func localizationBundle(_ localization: String) -> Bundle? {
        let base: Bundle = {
            #if SWIFT_PACKAGE
            return .module
            #else
            return .main
            #endif
        }()
        return base.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// Name given to a chapter whose book supplies no title ("Chapter 3" / "Capítulo 3").
    static func fallbackChapterName(_ number: Int) -> String {
        string("reader.chapter", number)
    }

    /// Chapter count of one book's offline audio.
    static func downloadedChapters(_ count: Int) -> String {
        string(count == 1 ? "settings.downloadedChapters.one" : "settings.downloadedChapters", count)
    }

    private static var defaultBundle: Bundle {
        if let bundleOverrideForTesting { return bundleOverrideForTesting }
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
