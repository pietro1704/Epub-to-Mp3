import Foundation

/// Chooses the `UserDefaults` that back the app's settings.
///
/// Normal launches use `UserDefaults.standard`. A UI test can pass
/// `-uiTestIsolatedSettings` to run against a throwaway suite instead, so a test
/// that changes narration, consent or reader preferences can never read or
/// overwrite the preferences of the real app installation (an aborted run cannot
/// leave Edge or online consent behind).
///
/// `-uiTestSpeechSelection piper:<model_id>` (or `system`, `edge`) additionally
/// seeds that primary narration in the throwaway suite, so a device journey can
/// pin the voice of its job without changing the saved choice of the installation.
///
/// The suite is emptied at every launch. A custom suite does not see the
/// launch-argument domain that `UserDefaults.standard` merges, so tests that
/// seed a preference through `-<key> <value>` must not opt in.
enum SettingsDefaultsSource {
    static let launchArgument = "-uiTestIsolatedSettings"
    static let speechSelectionArgument = "-uiTestSpeechSelection"
    static let isolatedSuiteName = "com.pietrocode.epubtomp3.uitest-isolated-settings"

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        standard: UserDefaults = .standard,
        suiteName: String = isolatedSuiteName
    ) -> UserDefaults {
        let seeded = seededPrimary(arguments)
        guard arguments.contains(launchArgument) || seeded != nil,
              let suite = UserDefaults(suiteName: suiteName) else { return standard }
        suite.removePersistentDomain(forName: suiteName)
        if let seeded, let data = try? JSONEncoder().encode(seeded) {
            suite.set(data, forKey: SpeechPreferenceMigration.Key.primarySelection)
        }
        return suite
    }

    /// `engine[:model_id]` after `-uiTestSpeechSelection`; anything else is ignored.
    static func seededPrimary(_ arguments: [String]) -> TtsSelection? {
        guard let index = arguments.firstIndex(of: speechSelectionArgument), index + 1 < arguments.count else {
            return nil
        }
        let parts = arguments[index + 1].split(separator: ":", maxSplits: 1).map(String.init)
        guard let engine = parts.first, TtsSelection.selectableEngines.contains(engine) else { return nil }
        if engine == TtsSelection.piperEngine, parts.count == 2 {
            return TtsSelection(engine: engine, modelID: parts[1], voice: nil)
        }
        return .engineDefault(engine)
    }
}
