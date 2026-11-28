#if os(macOS)
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
        // The artwork's pixel size must not drive layout: at the default priority a
        // large cover forces the hidden overlay, and with it the window, to grow.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            loadingCoverView.setContentCompressionResistancePriority(.defaultLow, for: axis)
            loadingCoverView.setContentHuggingPriority(.defaultLow, for: axis)
        }

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isIndeterminate = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false

        loadingTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        loadingTitleLabel.alignment = .center
        loadingTitleLabel.lineBreakMode = .byTruncatingTail
        loadingStatusLabel.textColor = .readableSecondaryLabel
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
        // Below .windowSizeStayPut: a preference this strong (it stays active
        // while the overlay is hidden) made Auto Layout shrink the window until
        // 28% of the reader width fit the 240 pt cap, so the reader never grew
        // past ~1138 pt, even in full screen (MAC-WINDOW-ADAPT).
        preferredCoverWidth.priority = .windowSizeStayPut - 1
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
        loadingCoverView.image = book.displayCoverPNG.flatMap(NSImage.init(data:))
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
