#if os(iOS)
import UIKit

@MainActor
final class ReaderLoadingPresentation {
    let loadingContainer = UIView()
    let loadingCoverView = UIImageView()
    let loadingSpinner = UIActivityIndicatorView(style: .large)
    let loadingStatusLabel = UILabel()
    let loadingRetryButton = UIButton(type: .system)

    func configure(target: AnyObject, retryAction: Selector, in view: UIView) {
        // Loading overlay: cover + spinner, shown in place of the chooser/
        // chrome (TOC, footnotes, search) while `loadBook()` is in flight.
        // Tapping a book must show ITS content, not a menu — this is the
        // only thing visible until `fulltext` is ready.
        loadingCoverView.contentMode = .scaleAspectFit
        loadingCoverView.tintColor = .tintColor
        loadingCoverView.layer.cornerRadius = 12
        loadingCoverView.layer.masksToBounds = true
        loadingCoverView.accessibilityIdentifier = "reader.loadingCover"
        loadingCoverView.isAccessibilityElement = true
        loadingCoverView.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingStatusLabel.textColor = .secondaryLabel
        loadingStatusLabel.textAlignment = .center
        loadingStatusLabel.numberOfLines = 0
        loadingStatusLabel.accessibilityIdentifier = "reader.loadingStatus"
        loadingRetryButton.setTitle(L10n.string("reader.retry"), for: .normal)
        loadingRetryButton.accessibilityIdentifier = "reader.loadingRetry"
        loadingRetryButton.addTarget(target, action: retryAction, for: .touchUpInside)
        let loadingStack = UIStackView(arrangedSubviews: [loadingCoverView, loadingSpinner, loadingStatusLabel, loadingRetryButton])
        loadingStack.axis = .vertical
        loadingStack.alignment = .center
        loadingStack.spacing = 16
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.backgroundColor = .systemBackground
        // A process-warm payload is rendered before `loadBook()` presents a
        // loading state. Keep the overlay hidden by default so that first
        // frame is the saved chapter rather than a flash of the cover.
        loadingContainer.isHidden = true
        loadingContainer.addSubview(loadingStack)
        loadingContainer.accessibilityIdentifier = "reader.loadingOverlay"
        view.addSubview(loadingContainer)
        let loadingMarginLeading = loadingStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.leadingAnchor, constant: 32
        )
        let loadingMarginTrailing = loadingStack.trailingAnchor.constraint(
            lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.trailingAnchor, constant: -32
        )
        loadingMarginLeading.priority = .required - 1
        loadingMarginTrailing.priority = .required - 1
        let preferredLoadingCoverWidth = loadingCoverView.widthAnchor.constraint(
            equalTo: loadingContainer.safeAreaLayoutGuide.widthAnchor,
            multiplier: ReaderLoadingLayoutMetrics.preferredCoverWidthFraction
        )
        preferredLoadingCoverWidth.priority = .defaultHigh
        let loadingCoverAspectRatio = loadingCoverView.heightAnchor.constraint(
            equalTo: loadingCoverView.widthAnchor,
            multiplier: ReaderLoadingLayoutMetrics.coverAspectRatio
        )
        loadingCoverAspectRatio.priority = .required
        let preferredLoadingTop = loadingStack.topAnchor.constraint(
            equalTo: loadingContainer.safeAreaLayoutGuide.topAnchor,
            constant: ReaderLoadingLayoutMetrics.preferredTopSpacing
        )
        preferredLoadingTop.priority = .defaultHigh
        let fallbackLoadingCenter = loadingStack.centerYAnchor.constraint(
            equalTo: loadingContainer.centerYAnchor
        )
        fallbackLoadingCenter.priority = .defaultLow
        NSLayoutConstraint.activate([
            loadingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingContainer.topAnchor.constraint(equalTo: view.topAnchor),
            loadingContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadingStack.centerXAnchor.constraint(equalTo: loadingContainer.centerXAnchor),
            preferredLoadingTop,
            fallbackLoadingCenter,
            loadingStack.topAnchor.constraint(
                greaterThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.topAnchor,
                constant: ReaderLoadingLayoutMetrics.minimumVerticalMargin
            ),
            loadingStack.bottomAnchor.constraint(
                lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.bottomAnchor,
                constant: -ReaderLoadingLayoutMetrics.minimumVerticalMargin
            ),
            loadingMarginLeading,
            loadingMarginTrailing,
            loadingCoverView.widthAnchor.constraint(
                lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.widthAnchor,
                multiplier: ReaderLoadingLayoutMetrics.maximumCoverWidthFraction
            ),
            loadingCoverView.heightAnchor.constraint(
                lessThanOrEqualTo: loadingContainer.safeAreaLayoutGuide.heightAnchor,
                multiplier: ReaderLoadingLayoutMetrics.maximumCoverHeightFraction
            ),
            preferredLoadingCoverWidth,
            loadingCoverAspectRatio,
        ])

    }
}
#endif
