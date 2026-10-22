import Foundation
#if os(iOS)
import UIKit
#endif

enum PlayerTransportPresentation {
    static func configuredSkipInterval(forKey key: String) -> Int {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? 15
        return AppSettings.playbackSkipIntervals.contains(value) ? Int(value) : 15
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    #if os(iOS)
    @MainActor
    static func configureTransportButton(
        _ button: UIButton,
        actionTarget: AnyObject,
        image: String,
        action: Selector,
        pointSize: CGFloat = 22
    ) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.tintColor = .label
        button.addTarget(actionTarget, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        // 44pt is the HIG minimum tap target, but on a standard-width iPhone
        // five transport buttons (the 64pt play/pause icon alone needs more
        // than 44pt) cannot all satisfy it plus their minimum spacing at
        // once — that combination produced "Unable to simultaneously
        // satisfy constraints" every time the full player appeared. Priority
        // just below required lets Auto Layout shrink below 44pt on narrow
        // screens instead of throwing, while still holding 44pt whenever
        // there's room for it.
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        width.priority = .required - 1
        height.priority = .required - 1
        NSLayoutConstraint.activate([width, height])
    }

    @MainActor
    static func configureSecondaryButton(
        _ button: UIButton,
        actionTarget: AnyObject,
        image: String,
        title: String?,
        action: Selector?
    ) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: image)
        config.title = title
        config.imagePadding = 6
        button.configuration = config
        button.tintColor = .label
        button.translatesAutoresizingMaskIntoConstraints = false
        if let action {
            button.addTarget(actionTarget, action: action, for: .touchUpInside)
        }
        // See configureTransportButton: same narrow-screen conflict applies
        // to the secondary row (rate/TOC/sleep/AirPlay).
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        width.priority = .required - 1
        height.priority = .required - 1
        NSLayoutConstraint.activate([width, height])
    }
    #endif
}
