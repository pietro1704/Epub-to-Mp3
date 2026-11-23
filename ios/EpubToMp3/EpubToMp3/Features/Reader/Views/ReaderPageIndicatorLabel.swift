#if os(iOS)
import UIKit

/// The paginated reader's "x of y" indicator: text in a capsule whose colours contrast with the page.
final class ReaderPageIndicatorLabel: UILabel {
    private let insets = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func apply(_ appearance: ReaderPageIndicatorStyle.Appearance) {
        textColor = appearance.text
        backgroundColor = appearance.fill
    }
}
#endif
