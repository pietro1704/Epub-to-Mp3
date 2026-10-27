#if os(iOS)
import UIKit

@MainActor
final class ReaderNavigationPresentation {
    static let readerContentTopSpacing = ReaderNavigationLayoutMetrics.readerContentTopSpacing
    private var readerNavigationHeight: NSLayoutConstraint!
    private var visibility = VisibilityTransition()
    let readerNavigationBackground = AdaptiveMaterialView()
    let readerNavigationBar = UINavigationBar()
    let readerNavigationItem = UINavigationItem()

    func install(in view: UIView, target: AnyObject, closeAction: Selector) {
        readerNavigationBar.translatesAutoresizingMaskIntoConstraints = false
        readerNavigationBackground.translatesAutoresizingMaskIntoConstraints = false
        readerNavigationBar.accessibilityIdentifier = "reader.navigationBar"
        readerNavigationBar.setContentHuggingPriority(.required, for: .vertical)
        readerNavigationBar.setContentCompressionResistancePriority(.required, for: .vertical)
        readerNavigationBar.isTranslucent = true
        readerNavigationBar.prefersLargeTitles = false
        readerNavigationBar.items = [readerNavigationItem]
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.shadowColor = .clear
        readerNavigationBar.standardAppearance = appearance
        readerNavigationBar.scrollEdgeAppearance = appearance
        readerNavigationBar.compactAppearance = appearance

        let closeItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: target,
            action: closeAction
        )
        closeItem.accessibilityLabel = L10n.string("common.back")
        closeItem.accessibilityIdentifier = "reader.close"
        readerNavigationItem.leftBarButtonItem = closeItem

        readerNavigationItem.rightBarButtonItem = nil

        // A standalone UINavigationBar starts below the sensor area. Its
        // material continues to the screen edge so the bar remains attached
        // to the top while its controls still respect the safe area.
        view.addSubview(readerNavigationBackground)
        view.addSubview(readerNavigationBar)
        NSLayoutConstraint.activate([
            readerNavigationBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerNavigationBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerNavigationBackground.topAnchor.constraint(equalTo: view.topAnchor),
            readerNavigationBackground.bottomAnchor.constraint(equalTo: readerNavigationBar.bottomAnchor),
            readerNavigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerNavigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerNavigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        readerNavigationHeight = readerNavigationBar.heightAnchor.constraint(
            equalToConstant: ReaderNavigationLayoutMetrics.initialBarHeight
        )
        readerNavigationHeight.isActive = true
    }

    func updateHeight(in view: UIView) {
        guard view.bounds.width > 0 else { return }
        let fittedHeight = readerNavigationBar.sizeThatFits(
            CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        guard fittedHeight > 0,
              abs(readerNavigationHeight.constant - fittedHeight) > .ulpOfOne else {
            return
        }
        readerNavigationHeight.constant = fittedHeight
    }

    func applyLayout(
        shouldShow: Bool,
        animated: Bool,
        commitsLayout: Bool = true,
        readerTopToNavigation: NSLayoutConstraint?, readerTopToRoot: NSLayoutConstraint?,
        in view: UIView
    ) {
        if let readerTopToNavigation,
           let readerTopToRoot {
            NSLayoutConstraint.deactivate([readerTopToNavigation, readerTopToRoot])
            (shouldShow ? readerTopToNavigation : readerTopToRoot).isActive = true
        }

        guard let request = visibility.request(visible: shouldShow) else {
            if commitsLayout { view.layoutIfNeeded() }
            return
        }
        let animates = animated && !ProcessInfo.processInfo.arguments.contains("-uiTestReduceMotion")
        if shouldShow {
            let wasHidden = readerNavigationBar.isHidden
            readerNavigationBar.isHidden = false
            readerNavigationBackground.isHidden = false
            if animates && wasHidden {
                readerNavigationBar.alpha = 0
                readerNavigationBackground.alpha = 0
            }
        }

        let changes = {
            self.readerNavigationBar.alpha = shouldShow ? 1 : 0
            self.readerNavigationBackground.alpha = shouldShow ? 1 : 0
            if commitsLayout { view.layoutIfNeeded() }
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, self.visibility.isCurrent(request) else { return }
            self.readerNavigationBar.isHidden = !shouldShow
            self.readerNavigationBackground.isHidden = !shouldShow
        }
        guard animates else {
            changes()
            completion(true)
            return
        }
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : ReaderChromeTransitionMetrics.duration,
            delay: 0,
            options: ReaderChromeTransitionMetrics.animationOptions,
            animations: changes,
            completion: completion
        )
    }
}

private enum ReaderNavigationLayoutMetrics {
    /// Keeps glyphs and selection handles clear of iOS's floating navigation
    /// controls while preserving the bar's intrinsic platform height.
    static let initialBarHeight: CGFloat = 44
    static let readerContentTopSpacing: CGFloat = 12
}
#endif
