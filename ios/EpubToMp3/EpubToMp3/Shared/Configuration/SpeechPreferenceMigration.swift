import Foundation
import os

/// One-shot, versioned migration of the retired engine-enum speech keys
/// (`audioEngine`, `secondaryAudioEngine`) into the stored `TtsSelection`
/// model (`primaryTtsSelection`, `secondaryTtsSelection`).
///
/// It reads a store exactly as the enum-based settings did, so the primary,
/// secondary and online consent the user had stay the same:
///
/// - A decodable `primaryTtsSelection`/`secondaryTtsSelection` already won over
///   the engine keys and is kept as it is.
/// - Otherwise the engine key becomes that engine's default selection (Faber
///   for Piper). A store without any saved speech policy gets the shipped
///   default: Piper/Faber with the system voice as secondary.
/// - A secondary engine equal to the primary engine was already deleted by
///   every enum-based launch; it is dropped the same way.
///
/// Nothing the new model cannot represent is deleted. An unknown engine value,
/// an Edge secondary saved without online consent, an engine key a decodable
/// selection shadows and the obsolete `ttsPreferencesVersion` marker stay on
/// disk untouched (and are logged). A selection that cannot be decoded is
/// copied byte for byte to `<key>.unreadable` (or the next free numbered
/// slot) before it is replaced.
///
/// Legacy keys are removed, and the version recorded, only after every value
/// written reads back equal. A failed run therefore leaves the legacy keys for
/// the next launch to retry from the same inputs, and a completed run is a no-op.
enum SpeechPreferenceMigration {
    static let versionKey = "speechPreferenceMigration.version"
    static let currentVersion = 1

    enum Key {
        static let legacyPrimaryEngine = "audioEngine"
        static let legacySecondaryEngine = "secondaryAudioEngine"
        static let legacyPolicyVersion = "ttsPreferencesVersion"
        static let primarySelection = "primaryTtsSelection"
        static let secondarySelection = "secondaryTtsSelection"
        static let onlineFallbackConsent = "allowOnlineAudioFallback"
        /// Where an undecodable selection is copied; a later slot is used when
        /// an earlier one already holds different data.
        static func unreadableCopy(of key: String, slot: Int = 1) -> String {
            slot == 1 ? key + ".unreadable" : key + ".unreadable.\(slot)"
        }
    }

    struct Outcome: Equatable {
        /// New-model keys written by this run.
        var written: [String] = []
        /// Legacy keys removed after their replacement verified.
        var removed: [String] = []
        /// Legacy or unreadable values deliberately left on disk.
        var preserved: [String] = []
        /// Unreadable selections copied to `<key>.unreadable`.
        var copiedUnreadable: [String] = []
        var completed = false
    }

    private enum StoredSelection {
        case absent
        case decoded(TtsSelection)
        case unreadable(Any)
    }

    private static let log = Logger(subsystem: "epub2mp3", category: "Settings")

    /// Reads a stored selection; any present value that does not decode is unreadable.
    static func decodeSelection(_ defaults: UserDefaults, key: String) -> TtsSelection? {
        if case let .decoded(selection) = stored(defaults, key: key) { return selection }
        return nil
    }

    @discardableResult
    static func runIfNeeded(_ defaults: UserDefaults) -> Outcome {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return Outcome(completed: true) }
        var run = Run(defaults: defaults)
        run.migratePrimary()
        run.migrateSecondary()
        if run.verified {
            // Legacy keys go only after every new value verified, so a retry
            // after a failed run still reads the original store.
            for key in run.pendingRemovals {
                defaults.removeObject(forKey: key)
                run.outcome.removed.append(key)
            }
            defaults.set(currentVersion, forKey: versionKey)
            run.outcome.completed = true
        } else {
            log.error("Speech preference migration did not verify; legacy keys kept for the next launch")
        }
        return run.outcome
    }

    private struct Run {
        let defaults: UserDefaults
        var outcome = Outcome()
        var verified = true
        var pendingRemovals: [String] = []
        /// The engine the enum-based settings narrated with: unknown or absent means Piper.
        let legacyPrimaryEngine: String
        let legacyPrimaryIsKnown: Bool
        let onlineConsent: Bool
        let hasSavedSpeechPolicy: Bool

        init(defaults: UserDefaults) {
            self.defaults = defaults
            if let stored = defaults.string(forKey: Key.legacyPrimaryEngine),
               TtsSelection.selectableEngines.contains(stored) {
                legacyPrimaryEngine = stored
                legacyPrimaryIsKnown = true
            } else {
                legacyPrimaryEngine = TtsSelection.piperEngine
                legacyPrimaryIsKnown = false
            }
            onlineConsent = defaults.bool(forKey: Key.onlineFallbackConsent)
            // A missing secondary in old settings may be an explicit no-fallback
            // choice. Only an entirely unconfigured speech policy adopts defaults.
            hasSavedSpeechPolicy = [Key.legacyPrimaryEngine, Key.legacySecondaryEngine,
                                    Key.onlineFallbackConsent, Key.legacyPolicyVersion]
                .contains { defaults.object(forKey: $0) != nil }
            if defaults.object(forKey: Key.legacyPolicyVersion) != nil {
                outcome.preserved.append(Key.legacyPolicyVersion)
            }
        }

        mutating func migratePrimary() {
            let legacyKeyPresent = defaults.object(forKey: Key.legacyPrimaryEngine) != nil
            if legacyKeyPresent && !legacyPrimaryIsKnown {
                preserve(Key.legacyPrimaryEngine, reason: "unknown engine value")
            }
            switch SpeechPreferenceMigration.stored(defaults, key: Key.primarySelection) {
            case let .decoded(selection):
                guard legacyPrimaryIsKnown else { return }
                if selection.engine == legacyPrimaryEngine {
                    remove(Key.legacyPrimaryEngine)
                } else {
                    preserve(Key.legacyPrimaryEngine, reason: "differs from the saved primary selection")
                }
            case .absent:
                guard legacyKeyPresent ? legacyPrimaryIsKnown : true else { return }
                if write(.engineDefault(legacyPrimaryEngine), to: Key.primarySelection), legacyKeyPresent {
                    remove(Key.legacyPrimaryEngine)
                }
            case let .unreadable(value):
                guard copyUnreadable(value, from: Key.primarySelection) else { return }
                if write(.engineDefault(legacyPrimaryEngine), to: Key.primarySelection),
                   legacyKeyPresent && legacyPrimaryIsKnown {
                    remove(Key.legacyPrimaryEngine)
                }
            }
        }

        mutating func migrateSecondary() {
            let stored = SpeechPreferenceMigration.stored(defaults, key: Key.secondarySelection)
            if case .decoded = stored {
                if defaults.object(forKey: Key.legacySecondaryEngine) != nil {
                    preserve(Key.legacySecondaryEngine, reason: "shadowed by the saved secondary selection")
                }
                return
            }
            if case let .unreadable(value) = stored {
                guard copyUnreadable(value, from: Key.secondarySelection) else { return }
            }
            let replacement = legacySecondary()
            if let replacement {
                guard write(replacement.selection, to: Key.secondarySelection) else { return }
            } else if case .unreadable = stored {
                defaults.removeObject(forKey: Key.secondarySelection)
            }
            if replacement?.consumesLegacyKey ?? consumesRejectedLegacyKey {
                remove(Key.legacySecondaryEngine)
            }
        }

        /// The secondary the enum-based settings narrated with, if any.
        private mutating func legacySecondary() -> (selection: TtsSelection, consumesLegacyKey: Bool)? {
            guard hasSavedSpeechPolicy else { return (.systemDefault, false) }
            guard let engine = defaults.string(forKey: Key.legacySecondaryEngine) else {
                if defaults.object(forKey: Key.legacySecondaryEngine) != nil {
                    preserve(Key.legacySecondaryEngine, reason: "unknown engine value")
                }
                return nil
            }
            guard TtsSelection.selectableEngines.contains(engine) else {
                preserve(Key.legacySecondaryEngine, reason: "unknown engine value")
                return nil
            }
            let candidate = TtsSelection.engineDefault(engine)
            if candidate.canBeSecondary(to: .engineDefault(legacyPrimaryEngine), allowOnlineFallback: onlineConsent) {
                return (candidate, true)
            }
            if engine != legacyPrimaryEngine {
                preserve(Key.legacySecondaryEngine, reason: "Edge secondary without online consent")
            }
            return nil
        }

        /// A rejected legacy secondary is deleted only when it repeated the primary engine.
        private var consumesRejectedLegacyKey: Bool {
            defaults.string(forKey: Key.legacySecondaryEngine) == legacyPrimaryEngine
                && !outcome.preserved.contains(Key.legacySecondaryEngine)
        }

        private mutating func write(_ selection: TtsSelection, to key: String) -> Bool {
            do {
                defaults.set(try JSONEncoder().encode(selection), forKey: key)
            } catch {
                SpeechPreferenceMigration.log.error("Could not encode \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                verified = false
                return false
            }
            guard SpeechPreferenceMigration.decodeSelection(defaults, key: key) == selection else {
                SpeechPreferenceMigration.log.error("\(key, privacy: .public) did not read back after migration")
                verified = false
                return false
            }
            outcome.written.append(key)
            return true
        }

        private mutating func copyUnreadable(_ value: Any, from key: String) -> Bool {
            let slots = (1...9).map { Key.unreadableCopy(of: key, slot: $0) }
            let sameCopy = slots.first { (defaults.object(forKey: $0) as AnyObject?)?.isEqual(value) == true }
            guard let copyKey = sameCopy ?? slots.first(where: { defaults.object(forKey: $0) == nil }) else {
                SpeechPreferenceMigration.log.error("No free copy slot for \(key, privacy: .public); left untouched")
                preserve(key, reason: "unreadable and every copy slot is taken")
                verified = false
                return false
            }
            if sameCopy == nil { defaults.set(value, forKey: copyKey) }
            guard let copied = defaults.object(forKey: copyKey), (copied as AnyObject).isEqual(value) else {
                SpeechPreferenceMigration.log.error("\(copyKey, privacy: .public) did not read back; \(key, privacy: .public) left untouched")
                preserve(key, reason: "unreadable copy did not verify")
                verified = false
                return false
            }
            SpeechPreferenceMigration.log.error("\(key, privacy: .public) could not be decoded; copied to \(copyKey, privacy: .public)")
            outcome.copiedUnreadable.append(key)
            return true
        }

        private mutating func remove(_ key: String) {
            if !pendingRemovals.contains(key) { pendingRemovals.append(key) }
        }

        private mutating func preserve(_ key: String, reason: String) {
            guard !outcome.preserved.contains(key) else { return }
            SpeechPreferenceMigration.log.notice("Speech preference \(key, privacy: .public) left untouched: \(reason, privacy: .public)")
            outcome.preserved.append(key)
        }
    }

    private static func stored(_ defaults: UserDefaults, key: String) -> StoredSelection {
        guard let value = defaults.object(forKey: key) else { return .absent }
        guard let data = value as? Data,
              let selection = try? JSONDecoder().decode(TtsSelection.self, from: data) else {
            return .unreadable(value)
        }
        return .decoded(selection)
    }
}
