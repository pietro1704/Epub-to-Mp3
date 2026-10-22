#if os(macOS)
import AppKit

enum EpubToMp3WindowConfiguration {
    static let macOSMinimumSize = CGSize(width: 1000, height: 700)
    static let macOSDefaultSize = CGSize(width: 1100, height: 760)

    @MainActor
    static func makeMacOSWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: macOSDefaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = macOSMinimumSize
        window.isRestorable = false
        return window
    }
    @MainActor
    static func centerOnActiveScreen(_ window: NSWindow) {
        // NSScreen.main can refer to a stale virtual display after a monitor
        // disconnect. The first screen is AppKit's primary display; clamp
        // the calculated frame to its visible area so a new window remains
        // reachable even when another display is arranged above it.
        let screen = NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        var frame = window.frame
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: false)
    }
}
#endif
