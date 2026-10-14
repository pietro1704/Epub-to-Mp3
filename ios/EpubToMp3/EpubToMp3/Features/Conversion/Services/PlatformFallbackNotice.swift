import Foundation
#if !APP_FOUNDATION_HOST_TESTS
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#endif

/// Each conversion callback box owns one tracker; another job gets a fresh notice.
final class PlatformFallbackNoticeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var notified = false

    func shouldNotify(progress: Data) -> Bool {
        guard let fields = try? JSONSerialization.jsonObject(with: progress) as? [String: Any],
              fields["engine"] as? String == "system" else { return false }
        lock.lock(); defer { lock.unlock() }
        guard !notified else { return false }
        notified = true
        return true
    }
}

/// A passive notice: changing providers never pauses playback or asks permission.
@MainActor
enum PlatformFallbackNotice {
    static func show() {
#if !APP_FOUNDATION_HOST_TESTS
        let message = L10n.string("conversion.systemVoiceFallback")
#if os(iOS)
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow),
              let surface = window.rootViewController?.view else { return }
        let label = UILabel()
        label.text = message
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textAlignment = .center
        label.textColor = .label
        label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: surface.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: surface.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: surface.safeAreaLayoutGuide.topAnchor, constant: 12),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        UIAccessibility.post(notification: .announcement, argument: message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { label.removeFromSuperview() }
#elseif os(macOS)
        guard let surface = (NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first)?.contentView else { return }
        let label = NSTextField(wrappingLabelWithString: message)
        label.drawsBackground = true
        label.backgroundColor = .windowBackgroundColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: surface.topAnchor, constant: 16),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        NSAccessibility.post(element: surface, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { label.removeFromSuperview() }
#endif
#endif
    }
}
