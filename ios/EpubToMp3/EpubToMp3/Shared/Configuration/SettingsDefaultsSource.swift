import Foundation

/// Chooses the `UserDefaults` that back the app's settings.
///
/// Normal launches use `UserDefaults.standard`. A UI test can pass
/// `-uiTestIsolatedSettings` to run against a throwaway suite instead, so a test
/// that changes narration, consent or reader preferences can never read or
/// overwrite the preferences of the real app installation (an aborted run cannot
/// leave Edge or online consent behind).
///
/// The suite is emptied at every launch. A custom suite does not see the
/// launch-argument domain that `UserDefaults.standard` merges, so tests that
/// seed a preference through `-<key> <value>` must not opt in.
enum SettingsDefaultsSource {
    static let launchArgument = "-uiTestIsolatedSettings"
    static let isolatedSuiteName = "com.pietrocode.epubtomp3.uitest-isolated-settings"

    static func resolve(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        standard: UserDefaults = .standard,
        suiteName: String = isolatedSuiteName
    ) -> UserDefaults {
        guard arguments.contains(launchArgument), let suite = UserDefaults(suiteName: suiteName) else {
            return standard
        }
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }
}
