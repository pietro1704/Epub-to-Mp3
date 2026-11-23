#if os(iOS)
import UIKit

/// The paginated reader's "x of y" indicator: the reader's text colour on a solid strip of the page colour, below the
/// text area (it never overlaps text).
final class ReaderPageIndicatorLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    func apply(_ appearance: ReaderPageIndicatorStyle.Appearance) {
        textColor = appearance.text
        backgroundColor = appearance.fill
    }
}
#endif
