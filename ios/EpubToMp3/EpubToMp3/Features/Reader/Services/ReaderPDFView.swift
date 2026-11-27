#if os(iOS)
import PDFKit
import UIKit

/// PDF text remains available for hit testing and accessibility, while selection
/// and the system editing menu belong to the app's explicit reading actions.
final class ReaderPDFView: PDFView {
    var onReaderTap: ((CGPoint) -> Void)?
    var onReaderLongPress: ((CGPoint) -> Void)?
    /// Called after a layout at a new size, with the page shown before it.
    var onViewportResize: ((PDFPage?) -> Void)?
    private var laidOutSize = CGSize.zero
    private lazy var readerGestureDelegate = ReaderPDFGestureDelegate(view: self)
    private lazy var readerTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var readerLongPress = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        readerTap.delegate = readerGestureDelegate
        readerLongPress.delegate = readerGestureDelegate
        readerTap.cancelsTouchesInView = false
        readerTap.require(toFail: readerLongPress)
        addGestureRecognizer(readerTap)
        addGestureRecognizer(readerLongPress)
        accessibilityIdentifier = "reader.pdf"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        readerTap.view?.removeGestureRecognizer(readerTap)
        readerLongPress.view?.removeGestureRecognizer(readerLongPress)
        // PDFKit reconfigures recognizers inside its own view hierarchy when
        // documents/pages change. App actions belong to the containing surface.
        if let superview {
            readerTap.isEnabled = true
            readerLongPress.isEnabled = true
            superview.addGestureRecognizer(readerTap)
            superview.addGestureRecognizer(readerLongPress)
        }
    }

    override var canBecomeFirstResponder: Bool { false }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func layoutSubviews() {
        let resized = bounds.size != laidOutSize
        let pageBeforeLayout = resized ? currentPage : nil
        laidOutSize = bounds.size
        super.layoutSubviews()
        if resized { onViewportResize?(pageBeforeLayout) }
        prepareForReaderInteraction()
        if currentSelection != nil { clearSelection() }
    }

    func prepareForReaderInteraction() {
        disableNativeSelection(in: self)
    }

    private func disableNativeSelection(in view: UIView) {
        for interaction in view.interactions {
            if interaction is UITextInteraction || interaction is UIContextMenuInteraction {
                view.removeInteraction(interaction)
            } else if #available(iOS 16.0, *), interaction is UIEditMenuInteraction {
                view.removeInteraction(interaction)
            }
        }
        for gesture in view.gestureRecognizers ?? [] where gesture !== readerLongPress {
            if gesture is UILongPressGestureRecognizer { gesture.isEnabled = false }
        }
        view.subviews.forEach { disableNativeSelection(in: $0) }
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onReaderTap?(gesture.location(in: self))
    }
    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        clearSelection()
        onReaderLongPress?(gesture.location(in: self))
    }
}

/// Only app recognizers use this delegate. PDFKit's optional Objective-C
/// delegate methods must stay with PDFKit, without superclass forwarding.
private final class ReaderPDFGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var view: ReaderPDFView?
    init(view: ReaderPDFView) { self.view = view }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { view != nil }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view else { return false }
        // Page turns can install PDFKit text interactions after the last layout.
        // Remove their menus before this touch can begin a native selection.
        view.prepareForReaderInteraction()
        return touch.view?.isDescendant(of: view) == true && view.bounds.contains(touch.location(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

#endif
