#if os(iOS)
import UIKit

@MainActor
final class ReaderNavigationPresentation {
    static let readerContentTopSpacing = ReaderNavigationLayoutMetrics.readerContentTopSpacing
    private var readerNavigationHeight: NSLayoutConstraint!
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

        if shouldShow {
            readerNavigationBar.isHidden = false
            readerNavigationBackground.isHidden = false
            if animated { readerNavigationBar.alpha = 0 }
            if animated { readerNavigationBackground.alpha = 0 }
        } else if !animated {
            readerNavigationBar.alpha = 0
            readerNavigationBar.isHidden = true
            readerNavigationBackground.alpha = 0
            readerNavigationBackground.isHidden = true
        }

        let changes = {
            self.readerNavigationBar.alpha = shouldShow ? 1 : 0
            self.readerNavigationBackground.alpha = shouldShow ? 1 : 0
            view.layoutIfNeeded()
        }
        guard animated else {
            // Visibility is presentation state, not committed reader geometry.
            // Restore alpha even when the root defers layout until its viewport
            // transaction finishes; otherwise a previously hidden toolbar stays
            // transparent after a centre tap restores reader chrome.
            readerNavigationBar.alpha = shouldShow ? 1 : 0
            readerNavigationBackground.alpha = shouldShow ? 1 : 0
            if commitsLayout { view.layoutIfNeeded() }
            return
        }
        UIView.animate(
            withDuration: ReaderChromeTransitionMetrics.duration,
            delay: 0,
            options: ReaderChromeTransitionMetrics.animationOptions,
            animations: changes
        ) { [weak self] _ in
            guard let self else { return }
            guard !shouldShow else { return }
            self.readerNavigationBar.isHidden = true
            self.readerNavigationBackground.isHidden = true
        }
    }
}

private enum ReaderNavigationLayoutMetrics {
    /// Keeps glyphs and selection handles clear of iOS's floating navigation
    /// controls while preserving the bar's intrinsic platform height.
    static let initialBarHeight: CGFloat = 44
    static let readerContentTopSpacing: CGFloat = 12
}
#endif
