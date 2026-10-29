import Foundation

/// New readers honor publisher paragraphs. Existing explicit controls retain
/// their intent even when their chosen value equals the old default.
struct ReaderParagraphPreferences {
    let overridesAlignment: Bool
    let overridesLineSpacing: Bool

    init(defaults: UserDefaults) {
        overridesAlignment = Self.overrides("readerOverrideTextAlignment", legacy: "readerTextAlignment", defaults: defaults)
        overridesLineSpacing = Self.overrides("readerOverrideLineSpacing", legacy: "readerLineSpacing", defaults: defaults)
    }

    private static func overrides(_ key: String, legacy: String, defaults: UserDefaults) -> Bool {
        if let explicit = defaults.object(forKey: key) as? Bool { return explicit }
        return defaults.object(forKey: legacy) != nil
    }
}
