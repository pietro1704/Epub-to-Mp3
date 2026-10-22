#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit
import Combine

@MainActor
final class MacReaderLoadingPresentation {
    let loadingOverlay = NSVisualEffectView()
    let loadingCoverView = NSImageView()
    let loadingSpinner = NSProgressIndicator()
    let loadingTitleLabel = NSTextField(labelWithString: "")
    let loadingStatusLabel = NSTextField(labelWithString: "")
    let loadingRetryButton = NSButton()
    private let cancelJourney: () -> Void

    init(cancelJourney: @escaping () -> Void) { self.cancelJourney = cancelJourney }

    func configure(in view: NSView, toolbar: NSStackView, target: AnyObject, retryAction: Selector) {
        loadingOverlay.material = .contentBackground
        loadingOverlay.blendingMode = .withinWindow
        loadingOverlay.state = .active
        loadingOverlay.isHidden = true
        loadingOverlay.setAccessibilityIdentifier("reader.loadingOverlay")
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        loadingCoverView.imageScaling = .scaleProportionallyUpOrDown
        loadingCoverView.wantsLayer = true
        loadingCoverView.layer?.cornerRadius = 12
        loadingCoverView.layer?.masksToBounds = true
        loadingCoverView.translatesAutoresizingMaskIntoConstraints = false

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isIndeterminate = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false

        loadingTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        loadingTitleLabel.alignment = .center
        loadingTitleLabel.lineBreakMode = .byTruncatingTail
        loadingStatusLabel.textColor = .secondaryLabelColor
        loadingStatusLabel.alignment = .center
        loadingStatusLabel.setAccessibilityIdentifier("reader.loadingStatus")
        loadingRetryButton.title = L10n.string("reader.retry")
        loadingRetryButton.bezelStyle = .rounded
        loadingRetryButton.target = target
        loadingRetryButton.action = retryAction
        loadingRetryButton.isHidden = true

        let stack = NSStackView(views: [
            loadingCoverView,
            loadingSpinner,
            loadingTitleLabel,
            loadingStatusLabel,
            loadingRetryButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(stack)
        view.addSubview(loadingOverlay)

        let preferredCoverWidth = loadingCoverView.widthAnchor.constraint(
            equalTo: loadingOverlay.widthAnchor,
            multiplier: 0.28
        )
        preferredCoverWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: loadingOverlay.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: loadingOverlay.trailingAnchor, constant: -32),
            preferredCoverWidth,
            loadingCoverView.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            loadingCoverView.heightAnchor.constraint(equalTo: loadingCoverView.widthAnchor, multiplier: 1.5),
            loadingCoverView.heightAnchor.constraint(lessThanOrEqualTo: loadingOverlay.heightAnchor, multiplier: 0.45),
        ])
        // The reader toolbar remains available for closing the book while
        // parsing continues underneath the loading surface.
        view.addSubview(toolbar, positioned: .above, relativeTo: loadingOverlay)
    }

    func showLoading(for book: BookEntity) {
        loadingCoverView.image = book.coverPNG.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        loadingTitleLabel.stringValue = book.resolvedTitle
        loadingStatusLabel.stringValue = L10n.string("reader.loading")
        loadingRetryButton.isHidden = true
        loadingOverlay.isHidden = false
        loadingSpinner.startAnimation(nil)
    }

    func showLoadingError(_ error: Error) {
        cancelJourney()
        loadingStatusLabel.stringValue = AppErrorReporter.message(error, context: "Reader loading")
        loadingRetryButton.isHidden = false
        loadingOverlay.isHidden = false
        loadingSpinner.stopAnimation(nil)
    }

    func hideLoading() {
        loadingSpinner.stopAnimation(nil)
        loadingOverlay.isHidden = true
    }

}
#endif
