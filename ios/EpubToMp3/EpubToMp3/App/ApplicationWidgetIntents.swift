import Foundation

/// Owns the process-wide widget notification and consumes its persisted commands.
@MainActor
enum ApplicationWidgetIntents {
    static let notificationName = "com.pietrocode.epubtomp3.widgetIntent"
    private static var sharedPlayer: AudioPlayer?

    static func bind(player: AudioPlayer) {
        sharedPlayer = player
    }

    static func drainPending(player: AudioPlayer) {
        guard let group = UserDefaults(suiteName: LibraryStore.appGroupID) else { return }
        consumePendingActions(defaults: group, togglePlayPause: player.togglePlayPause, skipForward: { player.skipForward() })
    }

    static func consumePendingActions(
        defaults: UserDefaults,
        togglePlayPause: () -> Void,
        skipForward: () -> Void
    ) {
        if defaults.bool(forKey: "widget.intent.togglePlayPause") {
            defaults.removeObject(forKey: "widget.intent.togglePlayPause")
            togglePlayPause()
        }
        if defaults.bool(forKey: "widget.intent.skipForward30") {
            defaults.removeObject(forKey: "widget.intent.skipForward30")
            skipForward()
        }
    }

    static func registerObserver() {
        registerObserver(isRunningUnderTests: EpubToMp3App.isRunningUnderXCTest()) {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                { _, _, _, _, _ in
                    Task { @MainActor in
                        guard let player = ApplicationWidgetIntents.sharedPlayer else { return }
                        ApplicationWidgetIntents.drainPending(player: player)
                    }
                },
                notificationName as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    static func registerObserver(isRunningUnderTests: Bool, registration: () -> Void) {
        guard !isRunningUnderTests else { return }
        registration()
    }
}
