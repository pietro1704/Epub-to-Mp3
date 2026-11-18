import Foundation

/// One-shot, versioned removal of persisted values whose features no longer
/// exist: the remote HTTP backend, the cellular conversion toggle, the offline
/// cache budget/TTL controls and the Continue reading widget payload. None of
/// these values has a current destination or any effect on behavior.
///
/// Data that could still matter to the user and cannot be migrated losslessly
/// is deliberately left on disk untouched: the old per-book reader positions
/// (`readPos_ch_*`, `readPos_pg_*`, page numbers without their pagination
/// geometry), the retired local conversion queue and legacy downloaded audio.
///
/// Each domain records its own completed version, so an App Group that is
/// unavailable at one launch is cleaned on a later one, and a repeated run is
/// a no-op.
enum LegacyPreferenceCleanup {
    static let versionKey = "legacyPreferenceCleanup.version"
    static let currentVersion = 1

    /// Keys written by `AppSettings` for removed settings.
    static let retiredStandardKeys = [
        "backendURL",
        "useEmbeddedRuntime",
        "allowCellularAudioConversion",
        "offlineCacheBudgetBytes",
        "offlineCacheTTLSeconds",
    ]

    /// App Group keys only the removed Continue reading widget read, plus the
    /// write-only conversion progress payload that no widget ever read.
    static let retiredAppGroupKeys = [
        "widget.lastReadBookId",
        "widget.lastReadChapterIndex",
        "widget.lastReadTotalChapters",
        "widget.lastReadChapterLabel",
        "widget.conversion.bookTitle",
        "widget.conversion.chaptersDone",
        "widget.conversion.chaptersTotal",
        "widget.conversion.currentChapterName",
    ]

    struct Outcome: Equatable {
        var standardKeysRemoved: [String] = []
        var appGroupKeysRemoved: [String] = []
        var standardCompleted = false
        var appGroupCompleted = false
    }

    @discardableResult
    static func runIfNeeded(standard: UserDefaults, appGroup: UserDefaults?) -> Outcome {
        var outcome = Outcome()
        outcome.standardKeysRemoved = clean(standard, keys: retiredStandardKeys)
        outcome.standardCompleted = standard.integer(forKey: versionKey) >= currentVersion
        if let appGroup {
            outcome.appGroupKeysRemoved = clean(appGroup, keys: retiredAppGroupKeys)
            outcome.appGroupCompleted = appGroup.integer(forKey: versionKey) >= currentVersion
        }
        return outcome
    }

    private static func clean(_ defaults: UserDefaults, keys: [String]) -> [String] {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return [] }
        let present = keys.filter { defaults.object(forKey: $0) != nil }
        present.forEach(defaults.removeObject(forKey:))
        defaults.set(currentVersion, forKey: versionKey)
        return present
    }
}
