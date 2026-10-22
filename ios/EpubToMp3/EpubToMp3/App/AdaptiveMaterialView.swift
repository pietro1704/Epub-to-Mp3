#if os(iOS)
import UIKit

@MainActor
final class AdaptiveMaterialView: UIVisualEffectView {
    init() {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            super.init(effect: UIGlassEffect(style: .regular))
        } else {
            super.init(effect: UIBlurEffect(style: .systemMaterial))
        }
#else
        super.init(effect: UIBlurEffect(style: .systemMaterial))
#endif
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif
