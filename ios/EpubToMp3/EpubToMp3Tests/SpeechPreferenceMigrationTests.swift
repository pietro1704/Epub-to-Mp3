import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

/// Real `UserDefaults` suites seeded with every value the enum-based speech
/// settings could leave behind.
final class SpeechPreferenceMigrationTests: XCTestCase {
    private typealias Key = SpeechPreferenceMigration.Key
    private var suites: [String] = []
    private let englishPiper = TtsSelection(
        engine: "piper", modelID: "en_US-ljspeech-high", voice: nil,
        session: TtsSessionSelection(provider: "piper", runtime: "piper-onnx", modelID: "en_US-ljspeech-high",
                                     modelRevision: "sha-en", voice: nil))
    private let unreadable = Data(#"{"model_id":"pt_BR-faber-medium"}"#.utf8)

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "speech-preference-migration-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func encoded(_ selection: TtsSelection) throws -> Data { try JSONEncoder().encode(selection) }
    private func selection(_ defaults: UserDefaults, _ key: String) -> TtsSelection? {
        SpeechPreferenceMigration.decodeSelection(defaults, key: key)
    }
    private func snapshot(_ defaults: UserDefaults, suite: String) -> NSDictionary {
        (defaults.persistentDomain(forName: suite) ?? [:]) as NSDictionary
    }

    // MARK: Named cases

    func testFreshStoreGetsFaberWithSystemSecondary() throws {
        let defaults = try makeDefaults()
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(selection(defaults, Key.primarySelection), .defaultPiper)
        XCTAssertEqual(selection(defaults, Key.secondarySelection), .systemDefault)
        XCTAssertEqual(outcome.written, [Key.primarySelection, Key.secondarySelection])
        XCTAssertEqual(outcome.removed, [])
        XCTAssertEqual(defaults.integer(forKey: SpeechPreferenceMigration.versionKey), 1)
        XCTAssertNil(defaults.object(forKey: Key.legacyPrimaryEngine))
        XCTAssertNil(defaults.object(forKey: Key.legacyPolicyVersion), "The obsolete marker is no longer written.")
    }

    func testPrimaryOnlyKeepsTheExplicitNoSecondaryChoice() throws {
        let defaults = try makeDefaults()
        defaults.set("edge", forKey: Key.legacyPrimaryEngine)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(selection(defaults, Key.primarySelection), .edgeDefault)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection), "A missing secondary was an explicit opt-out.")
        XCTAssertNil(defaults.object(forKey: Key.legacyPrimaryEngine))
        XCTAssertEqual(outcome.removed, [Key.legacyPrimaryEngine])
    }

    func testPrimaryWithSecondaryMovesBoth() throws {
        let defaults = try makeDefaults()
        defaults.set("piper", forKey: Key.legacyPrimaryEngine)
        defaults.set("system", forKey: Key.legacySecondaryEngine)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(selection(defaults, Key.primarySelection), .defaultPiper)
        XCTAssertEqual(selection(defaults, Key.secondarySelection), .systemDefault)
        XCTAssertEqual(Set(outcome.removed), [Key.legacyPrimaryEngine, Key.legacySecondaryEngine])
        XCTAssertEqual(outcome.preserved, [])
    }

    func testDuplicateSecondaryIsDroppedAsBefore() throws {
        let defaults = try makeDefaults()
        defaults.set("system", forKey: Key.legacyPrimaryEngine)
        defaults.set("system", forKey: Key.legacySecondaryEngine)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(selection(defaults, Key.primarySelection), .systemDefault)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))
        XCTAssertNil(defaults.object(forKey: Key.legacySecondaryEngine))
        XCTAssertTrue(outcome.removed.contains(Key.legacySecondaryEngine))
    }

    func testConsentedEdgeSecondaryMoves() throws {
        let defaults = try makeDefaults()
        defaults.set("piper", forKey: Key.legacyPrimaryEngine)
        defaults.set("edge", forKey: Key.legacySecondaryEngine)
        defaults.set(true, forKey: Key.onlineFallbackConsent)
        SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(selection(defaults, Key.secondarySelection), .edgeDefault)
        XCTAssertNil(defaults.object(forKey: Key.legacySecondaryEngine))
        XCTAssertTrue(defaults.bool(forKey: Key.onlineFallbackConsent), "Consent is kept as it is.")
    }

    func testUnconsentedEdgeSecondaryIsNotMigratedAndStaysOnDisk() throws {
        let defaults = try makeDefaults()
        defaults.set("piper", forKey: Key.legacyPrimaryEngine)
        defaults.set("edge", forKey: Key.legacySecondaryEngine)
        defaults.set(false, forKey: Key.onlineFallbackConsent)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(selection(defaults, Key.primarySelection), .defaultPiper)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection), "Edge never becomes a secondary without consent.")
        XCTAssertEqual(defaults.string(forKey: Key.legacySecondaryEngine), "edge")
        XCTAssertEqual(outcome.preserved, [Key.legacySecondaryEngine])
    }

    func testUnknownEngineValuesStayUntouched() throws {
        let defaults = try makeDefaults()
        defaults.set("kokoro", forKey: Key.legacyPrimaryEngine)
        defaults.set("espeak", forKey: Key.legacySecondaryEngine)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertTrue(outcome.completed)
        XCTAssertNil(defaults.object(forKey: Key.primarySelection), "An unknown primary was read as the default and stays unwritten.")
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))
        XCTAssertEqual(defaults.string(forKey: Key.legacyPrimaryEngine), "kokoro")
        XCTAssertEqual(defaults.string(forKey: Key.legacySecondaryEngine), "espeak")
        XCTAssertEqual(Set(outcome.preserved), [Key.legacyPrimaryEngine, Key.legacySecondaryEngine])
    }

    func testSavedSelectionsWinAndShadowedEngineKeysStay() throws {
        let defaults = try makeDefaults()
        defaults.set("system", forKey: Key.legacyPrimaryEngine)
        defaults.set("piper", forKey: Key.legacySecondaryEngine)
        defaults.set(try encoded(englishPiper), forKey: Key.primarySelection)
        defaults.set(try encoded(.systemDefault), forKey: Key.secondarySelection)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(selection(defaults, Key.primarySelection), englishPiper)
        XCTAssertEqual(selection(defaults, Key.secondarySelection), .systemDefault)
        XCTAssertEqual(outcome.written, [])
        XCTAssertEqual(defaults.string(forKey: Key.legacyPrimaryEngine), "system",
                       "An engine key that disagrees with the saved selection is not discarded.")
        XCTAssertEqual(defaults.string(forKey: Key.legacySecondaryEngine), "piper")
    }

    func testSavedPrimaryConsumesAMatchingEngineKey() throws {
        let defaults = try makeDefaults()
        defaults.set("piper", forKey: Key.legacyPrimaryEngine)
        defaults.set(try encoded(englishPiper), forKey: Key.primarySelection)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(selection(defaults, Key.primarySelection), englishPiper)
        XCTAssertNil(defaults.object(forKey: Key.legacyPrimaryEngine))
        XCTAssertEqual(outcome.removed, [Key.legacyPrimaryEngine])
    }

    func testUnreadableSelectionsAreCopiedBeforeTheEngineChoiceReplacesThem() throws {
        let defaults = try makeDefaults()
        defaults.set("system", forKey: Key.legacyPrimaryEngine)
        defaults.set("piper", forKey: Key.legacySecondaryEngine)
        defaults.set(unreadable, forKey: Key.primarySelection)
        defaults.set("not json", forKey: Key.secondarySelection)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(defaults.data(forKey: Key.unreadableCopy(of: Key.primarySelection)), unreadable)
        XCTAssertEqual(defaults.string(forKey: Key.unreadableCopy(of: Key.secondarySelection)), "not json")
        XCTAssertEqual(selection(defaults, Key.primarySelection), .systemDefault)
        XCTAssertEqual(selection(defaults, Key.secondarySelection), .defaultPiper)
        XCTAssertEqual(Set(outcome.copiedUnreadable), [Key.primarySelection, Key.secondarySelection])
        XCTAssertNil(defaults.object(forKey: Key.legacyPrimaryEngine))
        XCTAssertNil(defaults.object(forKey: Key.legacySecondaryEngine))
    }

    func testUnreadableSecondaryWithoutReplacementIsCopiedAndCleared() throws {
        let defaults = try makeDefaults()
        defaults.set("piper", forKey: Key.legacyPrimaryEngine)
        defaults.set(unreadable, forKey: Key.secondarySelection)
        SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(defaults.data(forKey: Key.unreadableCopy(of: Key.secondarySelection)), unreadable)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))
    }

    func testTakenCopySlotUsesTheNextSlotAndKeepsBothValues() throws {
        let defaults = try makeDefaults()
        let other = Data("other".utf8)
        defaults.set("system", forKey: Key.legacyPrimaryEngine)
        defaults.set(unreadable, forKey: Key.primarySelection)
        defaults.set(other, forKey: Key.unreadableCopy(of: Key.primarySelection))
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertTrue(outcome.completed)
        XCTAssertEqual(defaults.data(forKey: Key.unreadableCopy(of: Key.primarySelection)), other)
        XCTAssertEqual(defaults.data(forKey: Key.unreadableCopy(of: Key.primarySelection, slot: 2)), unreadable)
        XCTAssertEqual(selection(defaults, Key.primarySelection), .systemDefault)
        XCTAssertNil(defaults.object(forKey: Key.legacyPrimaryEngine))
    }

    func testPolicyMarkerAloneMeansAConfiguredStoreWithoutSecondary() throws {
        let defaults = try makeDefaults()
        defaults.set(2, forKey: Key.legacyPolicyVersion)
        let outcome = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(selection(defaults, Key.primarySelection), .defaultPiper)
        XCTAssertNil(defaults.object(forKey: Key.secondarySelection))
        XCTAssertEqual(defaults.integer(forKey: Key.legacyPolicyVersion), 2)
        XCTAssertEqual(outcome.preserved, [Key.legacyPolicyVersion])
    }

    func testSecondRunIsANoOp() throws {
        let suite = "speech-preference-migration-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("piper", forKey: Key.legacyPrimaryEngine)
        defaults.set("edge", forKey: Key.legacySecondaryEngine)
        SpeechPreferenceMigration.runIfNeeded(defaults)
        let migrated = snapshot(defaults, suite: suite)
        let second = SpeechPreferenceMigration.runIfNeeded(defaults)
        XCTAssertEqual(second, .init(completed: true))
        XCTAssertEqual(snapshot(defaults, suite: suite), migrated)
    }

    func testAlreadyMigratedStoreIsUntouched() throws {
        let suite = "speech-preference-migration-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(1, forKey: SpeechPreferenceMigration.versionKey)
        defaults.set("system", forKey: Key.legacyPrimaryEngine)
        defaults.set(try encoded(englishPiper), forKey: Key.primarySelection)
        let before = snapshot(defaults, suite: suite)
        XCTAssertEqual(SpeechPreferenceMigration.runIfNeeded(defaults), .init(completed: true))
        XCTAssertEqual(snapshot(defaults, suite: suite), before)
    }

    // MARK: Every combination against the enum-based reader

    private enum Seed { case absent, value(Any) }

    /// How the enum-based settings resolved a store (the removed
    /// `SpeechPreferenceMigration` struct, `AppSettings.init` and `ttsPreferences`).
    private func legacyEffective(_ defaults: UserDefaults) -> (TtsSelection, TtsSelection?, Bool) {
        func known(_ key: String) -> String? {
            defaults.string(forKey: key).flatMap { TtsSelection.selectableEngines.contains($0) ? $0 : nil }
        }
        let primaryEngine = known(Key.legacyPrimaryEngine) ?? "piper"
        let storedSecondary = known(Key.legacySecondaryEngine)
        let consent = defaults.bool(forKey: Key.onlineFallbackConsent)
        let saved = [Key.legacyPrimaryEngine, Key.legacySecondaryEngine, Key.onlineFallbackConsent,
                     Key.legacyPolicyVersion].contains { defaults.object(forKey: $0) != nil }
        var secondaryEngine = saved ? storedSecondary : "system"
        if storedSecondary == primaryEngine || (!consent && storedSecondary == "edge") { secondaryEngine = nil }
        func decoded(_ key: String) -> TtsSelection? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(TtsSelection.self, from: $0) }
        }
        let primary = decoded(Key.primarySelection) ?? .engineDefault(primaryEngine)
        let secondary = decoded(Key.secondarySelection) ?? secondaryEngine.flatMap {
            $0 != "edge" || consent ? TtsSelection.engineDefault($0) : nil
        }
        return (primary, secondary, consent)
    }

    /// A saved Edge primary without the online consent becomes the default Piper voice when the app loads its
    /// settings (a reserve that would now repeat the primary is dropped). The foundation host variant reads the
    /// defaults directly, so it keeps the legacy value.
    private static func afterTheEdgePrimaryDecision(
        _ effective: (TtsSelection, TtsSelection?, Bool)
    ) -> (TtsSelection, TtsSelection?, Bool) {
#if APP_FOUNDATION_HOST_TESTS
        return effective
#else
        guard effective.0.isEdge, !effective.2 else { return effective }
        let primary = TtsSelection.defaultPiper
        return (primary, effective.1.flatMap { $0.representsSameRequest(as: primary) ? nil : $0 }, effective.2)
#endif
    }

    /// How the current settings resolve a migrated store.
    private func currentEffective(_ defaults: UserDefaults) -> (TtsSelection, TtsSelection?, Bool) {
#if APP_FOUNDATION_HOST_TESTS
        SpeechPreferenceMigration.runIfNeeded(defaults)
        let consent = defaults.bool(forKey: Key.onlineFallbackConsent)
        let secondary = selection(defaults, Key.secondarySelection)
            .flatMap { $0.isAllowedAsFallback(allowOnlineFallback: consent) ? $0 : nil }
        return (selection(defaults, Key.primarySelection) ?? .defaultPiper, secondary, consent)
#else
        let preferences = AppSettings(defaults: defaults).ttsPreferences
        return (preferences.primary, preferences.secondary, preferences.allowOnlineFallback)
#endif
    }

    func testEveryLegacyCombinationKeepsTheEffectiveVoicesAndLosesNoValue() throws {
        let suite = "speech-preference-migration-grid-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let engines: [Seed] = [.absent, .value("piper"), .value("system"), .value("edge"), .value("kokoro")]
        let consents: [Seed] = [.absent, .value(false), .value(true)]
        let markers: [Seed] = [.absent, .value(2)]
        let selections: [Seed] = [.absent, .value(try encoded(englishPiper)), .value(unreadable)]
        var combinations = 0
        for primaryEngine in engines { for secondaryEngine in engines { for consent in consents {
            for marker in markers { for primary in selections { for secondary in selections {
                defaults.removePersistentDomain(forName: suite)
                let seeds: [(String, Seed)] = [
                    (Key.legacyPrimaryEngine, primaryEngine), (Key.legacySecondaryEngine, secondaryEngine),
                    (Key.onlineFallbackConsent, consent), (Key.legacyPolicyVersion, marker),
                    (Key.primarySelection, primary), (Key.secondarySelection, secondary),
                ]
                for case let (key, .value(value)) in seeds { defaults.set(value, forKey: key) }
                let seeded = snapshot(defaults, suite: suite)
                let label = "\(seeded)"
                let expected = Self.afterTheEdgePrimaryDecision(legacyEffective(defaults))

                let actual = currentEffective(defaults)
                XCTAssertEqual(actual.0, expected.0, "primary for \(label)")
                XCTAssertEqual(actual.1, expected.1, "secondary for \(label)")
                XCTAssertEqual(actual.2, expected.2, "consent for \(label)")
                XCTAssertEqual(defaults.integer(forKey: SpeechPreferenceMigration.versionKey), 1, label)

                // Every seeded value is still on disk, copied byte for byte, or
                // a legacy engine key whose choice now lives in a selection.
                let migrated = snapshot(defaults, suite: suite)
                for (key, value) in seeded {
                    guard let key = key as? String else { continue }
                    if let current = migrated[key], (current as AnyObject).isEqual(value) { continue }
                    if key == Key.primarySelection || key == Key.secondarySelection {
                        XCTAssertEqual(migrated[Key.unreadableCopy(of: key)] as? NSObject, value as? NSObject,
                                       "\(key) was replaced without a copy for \(label)")
                        continue
                    }
                    XCTAssertTrue([Key.legacyPrimaryEngine, Key.legacySecondaryEngine].contains(key),
                                  "\(key) changed for \(label)")
                    let engine = try XCTUnwrap(value as? String)
                    XCTAssertTrue(TtsSelection.selectableEngines.contains(engine), "unknown \(key) removed for \(label)")
                    // A removed engine key must now be represented: the primary
                    // carries it, or the secondary does, or it repeated the primary.
                    let primaryEngine = migrated[Key.primarySelection] == nil ? "piper"
                        : selection(defaults, Key.primarySelection)?.engine
                    if key == Key.legacyPrimaryEngine {
                        // The owner's decision: a saved Edge primary without the consent became default Piper.
                        let consented = (seeded[Key.onlineFallbackConsent] as? Bool) ?? false
                        let edgeWithoutConsent = engine == "edge" && !consented
#if APP_FOUNDATION_HOST_TESTS
                        let expectedEngine = engine
#else
                        let expectedEngine = edgeWithoutConsent ? "piper" : engine
#endif
                        XCTAssertEqual(primaryEngine, expectedEngine, "audioEngine removed without its choice for \(label)")
                    } else {
                        // A reserve that repeated the ORIGINAL primary stored nothing of its own; that stays true even when
                        // the owner's decision then turns an unconsented Edge primary into Piper.
                        let legacyPrimary = (seeded[Key.legacyPrimaryEngine] as? String)
                            .flatMap { TtsSelection.selectableEngines.contains($0) ? $0 : nil } ?? "piper"
                        XCTAssertTrue(selection(defaults, Key.secondarySelection) == .engineDefault(engine)
                                      || engine == legacyPrimary || engine == primaryEngine,
                                      "secondaryAudioEngine removed without its choice for \(label)")
                    }
                }

                let again = SpeechPreferenceMigration.runIfNeeded(defaults)
                XCTAssertEqual(again, .init(completed: true), label)
                XCTAssertEqual(snapshot(defaults, suite: suite), migrated, "second run changed \(label)")
                combinations += 1
            } } } } }
        }
        XCTAssertEqual(combinations, 5 * 5 * 3 * 2 * 3 * 3)
    }
}
