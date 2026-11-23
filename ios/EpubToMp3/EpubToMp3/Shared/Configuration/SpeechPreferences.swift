import Combine
import Foundation
import os.log

/// The user's narration choices and the rules between them, persisted in
/// `UserDefaults`.
///
/// It owns the primary and secondary `TtsSelection`, the online-fallback
/// consent and the automatic system-voice fallback, keeps the secondary valid
/// for the primary and the consent, and runs `SpeechPreferenceMigration`
/// before it reads the store. `AppSettings` exposes the same surface by
/// delegation and republishes its changes.
final class SpeechPreferences: ObservableObject {
    static let automaticSystemFallbackKey = "allowAutomaticSystemVoiceFallback"
    static let languageModelChoicesKey = "languageModelChoices.v1"
    private let defaults: UserDefaults
    private var loadingPersistedValues = true
    private static let log = Logger(subsystem: "epub2mp3", category: "Settings")

    init(defaults: UserDefaults) {
        self.defaults = defaults
        SpeechPreferenceMigration.runIfNeeded(defaults)
        self.primaryTtsSelection = Self.storedSelection(defaults, key: SpeechPreferenceMigration.Key.primarySelection)
            ?? .defaultPiper
        self.secondaryTtsSelection = Self.storedSelection(defaults, key: SpeechPreferenceMigration.Key.secondarySelection)
        self.allowOnlineAudioFallback = defaults.bool(forKey: SpeechPreferenceMigration.Key.onlineFallbackConsent)
        self.allowAutomaticSystemVoiceFallback =
            defaults.object(forKey: Self.automaticSystemFallbackKey) as? Bool ?? true
        self.languageModelChoices = Self.storedLanguageChoices(defaults)
        loadingPersistedValues = false
        migrateUnconsentedEdgePrimary()
    }

    /// Mirror of the Rust `TtsPreferences::migrate_unconsented_edge_primary` (the owner's decision): a saved Edge
    /// primary without the online consent becomes the default Piper voice and is saved; everything else, including
    /// the installed models and the consent, stays. With the consent nothing changes.
    private func migrateUnconsentedEdgePrimary() {
        guard primaryTtsSelection.isEdge, !allowOnlineAudioFallback else { return }
        selectPrimaryNarration(.defaultPiper)
    }

    /// Explicit narration choices, persisted as `TtsSelection` JSON. Change them
    /// through `selectPrimaryNarration` and `selectSecondaryNarration`, which keep
    /// the secondary valid for the primary and the online consent.
    @Published private(set) var primaryTtsSelection: TtsSelection = .defaultPiper {
        didSet {
            guard !loadingPersistedValues else { return }
            persist(primaryTtsSelection, forKey: SpeechPreferenceMigration.Key.primarySelection)
        }
    }
    @Published private(set) var secondaryTtsSelection: TtsSelection? = nil {
        didSet {
            guard !loadingPersistedValues else { return }
            persist(secondaryTtsSelection, forKey: SpeechPreferenceMigration.Key.secondarySelection)
        }
    }
    @Published var allowAutomaticSystemVoiceFallback = true {
        didSet {
            guard !loadingPersistedValues else { return }
            defaults.set(allowAutomaticSystemVoiceFallback, forKey: Self.automaticSystemFallbackKey)
        }
    }
    @Published var allowOnlineAudioFallback = false {
        didSet {
            guard !loadingPersistedValues else { return }
            defaults.set(allowOnlineAudioFallback, forKey: SpeechPreferenceMigration.Key.onlineFallbackConsent)
            if secondaryTtsSelection?.isAllowedAsFallback(allowOnlineFallback: allowOnlineAudioFallback) == false {
                secondaryTtsSelection = nil
            }
        }
    }

    /// One optional explicit narration per BASE book language (`pt`, `en`, ...),
    /// persisted as JSON. Absent means automatic. Rust validates a choice when it
    /// resolves a book (an uninstalled or incompatible choice is skipped, never
    /// deleted), so nothing here depends on what is installed.
    @Published private(set) var languageModelChoices: [String: TtsSelection] = [:] {
        didSet {
            guard !loadingPersistedValues else { return }
            do {
                defaults.set(try JSONEncoder().encode(languageModelChoices), forKey: Self.languageModelChoicesKey)
            } catch {
                Self.log.error("Could not save the language model choices: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The stored key for a language: its lowercase base tag.
    static func languageKey(_ language: String) -> String {
        language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0).lowercased() } ?? language.lowercased()
    }

    func selectLanguageModel(_ selection: TtsSelection, for language: String) {
        languageModelChoices[Self.languageKey(language)] = selection
    }

    func clearLanguageModel(for language: String) {
        languageModelChoices.removeValue(forKey: Self.languageKey(language))
    }

    /// An undecodable value is logged and left on disk until the next explicit choice.
    private static func storedLanguageChoices(_ defaults: UserDefaults) -> [String: TtsSelection] {
        guard let data = defaults.data(forKey: languageModelChoicesKey) else { return [:] }
        guard let choices = try? JSONDecoder().decode([String: TtsSelection].self, from: data) else {
            log.error("Saved language model choices could not be decoded; using automatic until a new choice")
            return [:]
        }
        return choices
    }

    /// Makes `selection` the primary voice; a secondary that would now repeat
    /// it is cleared. Consent is not re-checked here: revoking it already clears
    /// an Edge secondary, and `ttsPreferences` never sends one without consent.
    func selectPrimaryNarration(_ selection: TtsSelection) {
        primaryTtsSelection = selection
        if secondaryTtsSelection?.representsSameRequest(as: selection) == true {
            secondaryTtsSelection = nil
        }
    }

    /// Sets or clears the secondary voice. A selection that repeats the primary,
    /// or Edge without online consent, is rejected and leaves no secondary.
    func selectSecondaryNarration(_ selection: TtsSelection?) {
        secondaryTtsSelection = selection.flatMap {
            $0.canBeSecondary(to: primaryTtsSelection, allowOnlineFallback: allowOnlineAudioFallback) ? $0 : nil
        }
    }

    /// Engine of the primary voice; it also names the reader's saved local audio.
    var primaryEngine: String { primaryTtsSelection.engine }

    /// Engine-default secondaries the user may pick for the current primary.
    var selectableSecondaryEngines: [String] {
        TtsSelection.selectableEngines.filter {
            TtsSelection.engineDefault($0).canBeSecondary(to: primaryTtsSelection,
                                                          allowOnlineFallback: allowOnlineAudioFallback)
        }
    }

    /// What conversion receives: a saved Edge secondary is left out without consent.
    var ttsPreferences: TtsPreferences {
        let secondary = secondaryTtsSelection.flatMap {
            $0.isAllowedAsFallback(allowOnlineFallback: allowOnlineAudioFallback) ? $0 : nil
        }
        return TtsPreferences(primary: primaryTtsSelection,
                              secondary: secondary,
                              allowOnlineFallback: allowOnlineAudioFallback,
                              policyVersion: allowAutomaticSystemVoiceFallback ? 2 : 3)
    }

    var configuredNarrationSelections: [TtsSelection] {
        [ttsPreferences.primary, ttsPreferences.secondary].compactMap { $0 }
    }

    /// A selection that cannot be decoded is logged and left on disk; it is
    /// only replaced when the user makes a new explicit choice.
    private static func storedSelection(_ defaults: UserDefaults, key: String) -> TtsSelection? {
        guard defaults.object(forKey: key) != nil else { return nil }
        guard let selection = SpeechPreferenceMigration.decodeSelection(defaults, key: key) else {
            log.error("Saved \(key, privacy: .public) could not be decoded; using the default until a new choice")
            return nil
        }
        return selection
    }

    /// An encoding failure keeps the previously saved choice instead of erasing it.
    private func persist(_ selection: TtsSelection?, forKey key: String) {
        guard let selection else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(selection), forKey: key)
        } catch {
            Self.log.error("Could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
