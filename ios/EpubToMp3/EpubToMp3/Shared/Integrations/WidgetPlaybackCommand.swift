import Foundation

/// Persists a command before notifying the host. The extension and app share
/// these literal identifiers; notification delivery is an injected side effect
/// so native tests can exercise ordering without waking a real application.
enum WidgetPlaybackCommand: String {
    case togglePlayPause = "widget.intent.togglePlayPause"
    case skipForward30 = "widget.intent.skipForward30"

    static let notificationName = "com.pietrocode.epubtomp3.widgetIntent"

    func send(defaults: UserDefaults?, notify: () -> Void = Self.notifyHost) {
        defaults?.set(true, forKey: rawValue)
        notify()
    }

    private static func notifyHost() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil, nil, true
        )
    }
}
